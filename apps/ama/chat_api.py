"""Chat API blueprint for amaPod events — free, moderated, or off modes."""

from flask import Blueprint, jsonify, request, session

from auth import require_auth, current_user
from db import get_db

bp = Blueprint("chat_api", __name__)


def _serialize_message(row):
    return {
        "id": row["id"],
        "event_id": row["event_id"],
        "sender_name": row["sender_name"],
        "is_host": row["is_host"],
        "message": row["message"],
        "is_approved": row["is_approved"],
        "created_at": row["created_at"],
    }


def _get_sender(db, eid):
    """Return (sender_name, is_host) from session or access_token."""
    username = session.get("username")
    if username:
        ev = db.execute("SELECT host_username FROM events WHERE id = ?", (eid,)).fetchone()
        is_host = ev and ev["host_username"] == username
        return username, bool(is_host)

    token = request.args.get("token") or (request.get_json(silent=True) or {}).get("token")
    if token:
        part = db.execute(
            "SELECT display_name FROM participants WHERE event_id = ? AND access_token = ?",
            (eid, token),
        ).fetchone()
        if part:
            return part["display_name"], False

    return None, False


@bp.post("/api/events/<int:eid>/chat")
def send_message(eid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404

        if ev["chat_mode"] == "off":
            return jsonify({"error": "el chat está desactivado"}), 403

        sender_name, is_host = _get_sender(db, eid)
        if not sender_name:
            return jsonify({"error": "no autenticado"}), 401

        data = request.get_json(silent=True) or {}
        message = (data.get("message") or "").strip()
        if not message:
            return jsonify({"error": "mensaje requerido"}), 400

        # In moderated mode, non-host messages require approval
        if ev["chat_mode"] == "moderated" and not is_host:
            is_approved = 0
        else:
            is_approved = 1

        cur = db.execute(
            "INSERT INTO chat_messages (event_id, sender_name, is_host, message, is_approved) VALUES (?, ?, ?, ?, ?)",
            (eid, sender_name, 1 if is_host else 0, message, is_approved),
        )
        db.commit()
        mid = cur.lastrowid
        row = db.execute("SELECT * FROM chat_messages WHERE id = ?", (mid,)).fetchone()
        return jsonify(_serialize_message(row)), 201
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/chat")
def list_messages(eid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404

        # Check auth (session or token)
        username = session.get("username")
        token = request.args.get("token")
        if not username and not token:
            return jsonify({"error": "no autenticado"}), 401
        if token and not username:
            part = db.execute(
                "SELECT id FROM participants WHERE event_id = ? AND access_token = ?",
                (eid, token),
            ).fetchone()
            if not part:
                return jsonify({"error": "token inválido"}), 401

        rows = db.execute(
            "SELECT * FROM chat_messages WHERE event_id = ? AND is_approved = 1 ORDER BY created_at ASC",
            (eid,),
        ).fetchall()
        return jsonify([_serialize_message(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/chat/<int:mid>/approve")
@require_auth
def approve_message(eid, mid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if ev["host_username"] != current_user():
            return jsonify({"error": "solo el host puede aprobar mensajes"}), 403

        msg = db.execute("SELECT * FROM chat_messages WHERE id = ? AND event_id = ?", (mid, eid)).fetchone()
        if not msg:
            return jsonify({"error": "mensaje no encontrado"}), 404

        db.execute("UPDATE chat_messages SET is_approved = 1 WHERE id = ?", (mid,))
        db.commit()
        row = db.execute("SELECT * FROM chat_messages WHERE id = ?", (mid,)).fetchone()
        return jsonify(_serialize_message(row))
    finally:
        db.close()


@bp.delete("/api/events/<int:eid>/chat/<int:mid>")
@require_auth
def delete_message(eid, mid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if ev["host_username"] != current_user():
            return jsonify({"error": "solo el host puede eliminar mensajes"}), 403

        msg = db.execute("SELECT * FROM chat_messages WHERE id = ? AND event_id = ?", (mid, eid)).fetchone()
        if not msg:
            return jsonify({"error": "mensaje no encontrado"}), 404

        db.execute("DELETE FROM chat_messages WHERE id = ?", (mid,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()
