"""Events API blueprint — CRUD, lifecycle, and templates for amaPod events."""

import json
from flask import Blueprint, jsonify, request

from auth import require_auth, current_user
from db import get_db
from livekit_service import create_room, delete_room, room_name_for_event

bp = Blueprint("events_api", __name__)


def _serialize_event(row):
    return {
        "id": row["id"],
        "title": row["title"],
        "description": row["description"],
        "status": row["status"],
        "chat_mode": row["chat_mode"],
        "livekit_room_name": row["livekit_room_name"],
        "egress_id": row["egress_id"],
        "recording_file": row["recording_file"],
        "shared_project_id": row["shared_project_id"],
        "prodpod_session_id": row["prodpod_session_id"],
        "branding_json": row["branding_json"],
        "like_count": row["like_count"],
        "spectator_count": row["spectator_count"],
        "host_username": row["host_username"],
        "created_at": row["created_at"],
        "started_at": row["started_at"],
        "finished_at": row["finished_at"],
    }


@bp.get("/api/events/<int:eid>/public-info")
def public_event_info(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404
        pcount = db.execute(
            "SELECT COUNT(*) AS c FROM participants WHERE event_id = ? AND status NOT IN ('rejected')",
            (eid,),
        ).fetchone()["c"]
        return jsonify({
            "id": row["id"],
            "title": row["title"],
            "description": row["description"],
            "status": row["status"],
            "host_username": row["host_username"],
            "like_count": row["like_count"],
            "spectator_count": row["spectator_count"],
            "participant_count": pcount,
        })
    finally:
        db.close()


@bp.post("/api/events")
@require_auth
def create_event():
    data = request.get_json(silent=True) or {}
    title = (data.get("title") or "").strip()
    if not title:
        return jsonify({"error": "título requerido"}), 400

    description = (data.get("description") or "").strip()
    chat_mode = data.get("chat_mode", "free")
    branding_json = data.get("branding_json")
    host = current_user()

    db = get_db()
    try:
        cur = db.execute(
            "INSERT INTO events (title, description, chat_mode, branding_json, host_username) "
            "VALUES (?, ?, ?, ?, ?)",
            (title, description, chat_mode, branding_json, host),
        )
        db.commit()
        eid = cur.lastrowid
        room_name = room_name_for_event(eid)
        db.execute("UPDATE events SET livekit_room_name = ? WHERE id = ?", (room_name, eid))
        db.commit()
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        return jsonify(_serialize_event(row)), 201
    finally:
        db.close()


@bp.get("/api/events")
@require_auth
def list_events():
    host = current_user()
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM events WHERE host_username = ? ORDER BY created_at DESC", (host,)
        ).fetchall()
        return jsonify([_serialize_event(r) for r in rows])
    finally:
        db.close()


@bp.get("/api/events/<int:eid>")
@require_auth
def get_event(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404
        return jsonify(_serialize_event(row))
    finally:
        db.close()


@bp.put("/api/events/<int:eid>")
@require_auth
def update_event(eid):
    data = request.get_json(silent=True) or {}
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404

        title = data.get("title", row["title"])
        description = data.get("description", row["description"])
        chat_mode = data.get("chat_mode", row["chat_mode"])

        db.execute(
            "UPDATE events SET title = ?, description = ?, chat_mode = ? WHERE id = ?",
            (title, description, chat_mode, eid),
        )
        db.commit()
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        return jsonify(_serialize_event(row))
    finally:
        db.close()


@bp.delete("/api/events/<int:eid>")
@require_auth
def delete_event(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404
        if row["status"] != "created":
            return jsonify({"error": "solo se puede eliminar un evento en estado 'created'"}), 400
        if row["livekit_room_name"]:
            delete_room(row["livekit_room_name"])
        db.execute("DELETE FROM events WHERE id = ?", (eid,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/start")
@require_auth
def start_event(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404
        if row["status"] != "created":
            return jsonify({"error": "el evento no está en estado 'created'"}), 400

        room_name = row["livekit_room_name"] or room_name_for_event(eid)
        create_room(room_name)

        db.execute(
            "UPDATE events SET status = 'active', livekit_room_name = ?, started_at = CURRENT_TIMESTAMP WHERE id = ?",
            (room_name, eid),
        )
        db.commit()
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        return jsonify(_serialize_event(row))
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/finish")
@require_auth
def finish_event(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404
        if row["status"] != "active":
            return jsonify({"error": "el evento no está activo"}), 400

        db.execute(
            "UPDATE events SET status = 'finished', finished_at = CURRENT_TIMESTAMP WHERE id = ?",
            (eid,),
        )
        db.execute(
            "UPDATE participants SET status = 'left' WHERE event_id = ? AND status NOT IN ('rejected', 'done', 'left')",
            (eid,),
        )
        db.commit()
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()

        # Auto-export recording to postPod (best-effort, don't block finish)
        if row["recording_file"]:
            try:
                from integrations import _do_export_to_postpod
                _do_export_to_postpod(eid)
            except Exception as e:
                import logging
                logging.getLogger(__name__).warning("Auto-export to postPod failed: %s", e)

        return jsonify(_serialize_event(row))
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/like")
def like_event(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404
        db.execute("UPDATE events SET like_count = like_count + 1 WHERE id = ?", (eid,))
        db.commit()
        row = db.execute("SELECT like_count FROM events WHERE id = ?", (eid,)).fetchone()
        return jsonify({"like_count": row["like_count"]})
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/spectator-token")
def spectator_token(eid):
    from livekit_service import generate_participant_token
    import uuid
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if ev["status"] != "active":
            return jsonify({"error": "el evento no esta activo"}), 400

        room_name = ev["livekit_room_name"] or room_name_for_event(eid)
        identity = f"spectator_{uuid.uuid4().hex[:8]}"
        token = generate_participant_token(
            room_name, identity, "Espectador",
            is_host=False, can_publish=False,
        )
        db.execute(
            "UPDATE events SET spectator_count = spectator_count + 1 WHERE id = ?",
            (eid,),
        )
        db.commit()
        return jsonify({"token": token, "room_name": room_name})
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/clone-template")
@require_auth
def clone_to_template(eid):
    db = get_db()
    try:
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not row:
            return jsonify({"error": "evento no encontrado"}), 404

        cur = db.execute(
            "INSERT INTO event_templates (title, description, chat_mode, branding_json, host_username) "
            "VALUES (?, ?, ?, ?, ?)",
            (row["title"], row["description"], row["chat_mode"], row["branding_json"], row["host_username"]),
        )
        db.commit()
        tid = cur.lastrowid
        tpl = db.execute("SELECT * FROM event_templates WHERE id = ?", (tid,)).fetchone()
        return jsonify({
            "id": tpl["id"],
            "title": tpl["title"],
            "description": tpl["description"],
            "chat_mode": tpl["chat_mode"],
            "branding_json": tpl["branding_json"],
            "host_username": tpl["host_username"],
            "created_at": tpl["created_at"],
        }), 201
    finally:
        db.close()


@bp.get("/api/events/templates")
@require_auth
def list_templates():
    host = current_user()
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM event_templates WHERE host_username = ? ORDER BY created_at DESC",
            (host,),
        ).fetchall()
        return jsonify([{
            "id": r["id"],
            "title": r["title"],
            "description": r["description"],
            "chat_mode": r["chat_mode"],
            "branding_json": r["branding_json"],
            "host_username": r["host_username"],
            "created_at": r["created_at"],
        } for r in rows])
    finally:
        db.close()


@bp.post("/api/events/from-template/<int:tid>")
@require_auth
def create_from_template(tid):
    db = get_db()
    try:
        tpl = db.execute("SELECT * FROM event_templates WHERE id = ?", (tid,)).fetchone()
        if not tpl:
            return jsonify({"error": "plantilla no encontrada"}), 404

        host = current_user()
        cur = db.execute(
            "INSERT INTO events (title, description, chat_mode, branding_json, host_username) "
            "VALUES (?, ?, ?, ?, ?)",
            (tpl["title"], tpl["description"], tpl["chat_mode"], tpl["branding_json"], host),
        )
        db.commit()
        eid = cur.lastrowid
        room_name = room_name_for_event(eid)
        db.execute("UPDATE events SET livekit_room_name = ? WHERE id = ?", (room_name, eid))
        db.commit()
        row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        return jsonify(_serialize_event(row)), 201
    finally:
        db.close()
