"""Queue / participant management API for amaPod events."""

import uuid
from flask import Blueprint, jsonify, request

from auth import require_auth, current_user
from db import get_db
from config import PRECONNECT_COUNT
from pod_push import notify as push_notify
from livekit_service import (
    generate_participant_token,
    mute_participant,
    update_participant_permissions,
    remove_participant as lk_remove_participant,
    room_name_for_event,
)

bp = Blueprint("queue_api", __name__)


def _serialize_participant(row):
    import json as _json
    questions = []
    try:
        questions = _json.loads(row["questions"] or "[]")
    except (ValueError, TypeError):
        pass
    return {
        "id": row["id"],
        "event_id": row["event_id"],
        "display_name": row["display_name"],
        "photo_url": row["photo_url"],
        "status": row["status"],
        "queue_position": row["queue_position"],
        "is_preconnected": row["is_preconnected"],
        "is_censored": row["is_censored"],
        "questions": questions,
        "requested_at": row["requested_at"],
        "approved_at": row["approved_at"],
        "turn_started_at": row["turn_started_at"],
        "turn_ended_at": row["turn_ended_at"],
    }


def _compact_queue(db, eid):
    """Re-number queue positions starting from 1 for in_queue participants."""
    rows = db.execute(
        "SELECT id FROM participants WHERE event_id = ? AND status = 'in_queue' ORDER BY queue_position ASC",
        (eid,),
    ).fetchall()
    for i, row in enumerate(rows, 1):
        db.execute("UPDATE participants SET queue_position = ? WHERE id = ?", (i, row["id"]))


def _update_preconnect_flags(db, eid):
    """Mark the next PRECONNECT_COUNT in-queue participants as preconnected."""
    db.execute(
        "UPDATE participants SET is_preconnected = 0 WHERE event_id = ? AND status = 'in_queue'",
        (eid,),
    )
    rows = db.execute(
        "SELECT id FROM participants WHERE event_id = ? AND status = 'in_queue' ORDER BY queue_position ASC LIMIT ?",
        (eid, PRECONNECT_COUNT),
    ).fetchall()
    for row in rows:
        db.execute("UPDATE participants SET is_preconnected = 1 WHERE id = ?", (row["id"],))


def _approx_position(pos):
    if pos is None:
        return "en la cola"
    if pos <= 5:
        return "entre los próximos 5"
    if pos <= 10:
        return "entre los próximos 10"
    if pos <= 20:
        return "entre los próximos 20"
    return "en la cola"


def _require_host(db, eid):
    """Return event row if current user is host, else (None, error_response)."""
    row = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
    if not row:
        return None, (jsonify({"error": "evento no encontrado"}), 404)
    if row["host_username"] != current_user():
        return None, (jsonify({"error": "solo el host puede realizar esta acción"}), 403)
    return row, None


# ── Public endpoints ─────────────────────────────────────────────────

@bp.post("/api/events/<int:eid>/request-access")
def request_access(eid):
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "nombre requerido"}), 400

    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404

        # Check duplicate
        existing = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND display_name = ?",
            (eid, name),
        ).fetchone()
        if existing:
            return jsonify({"error": "ya existe un participante con ese nombre"}), 409

        token = uuid.uuid4().hex
        cur = db.execute(
            "INSERT INTO participants (event_id, display_name, access_token, status) VALUES (?, ?, ?, 'pending')",
            (eid, name, token),
        )
        db.commit()
        pid = cur.lastrowid
        push_notify([ev["host_username"]], "amaPod · " + (ev["title"] or "evento"),
                    name + " pide la palabra", "/ama/", tag="ama-req-" + str(eid))
        return jsonify({"id": pid, "access_token": token, "status": "pending"}), 201
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/my-status")
def my_status(eid):
    token = request.args.get("token", "")
    if not token:
        return jsonify({"error": "token requerido"}), 400

    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND access_token = ?",
            (eid, token),
        ).fetchone()
        if not row:
            return jsonify({"error": "participante no encontrado"}), 404

        result = _serialize_participant(row)
        result["approximate_position"] = _approx_position(row["queue_position"])
        return jsonify(result)
    finally:
        db.close()


@bp.put("/api/events/<int:eid>/my-questions")
def update_my_questions(eid):
    import json as _json
    token = request.args.get("token", "")
    if not token:
        return jsonify({"error": "token requerido"}), 400

    data = request.get_json(silent=True) or {}
    raw = data.get("questions", [])
    if not isinstance(raw, list):
        return jsonify({"error": "questions debe ser una lista"}), 400

    questions = [str(q).strip() for q in raw[:3] if str(q).strip()]

    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND access_token = ?",
            (eid, token),
        ).fetchone()
        if not row:
            return jsonify({"error": "participante no encontrado"}), 404

        db.execute(
            "UPDATE participants SET questions = ? WHERE id = ?",
            (_json.dumps(questions), row["id"]),
        )
        db.commit()
        return jsonify({"questions": questions})
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/leave")
def leave_event(eid):
    """El participante se retira solo (con su token): sale de la cola o termina su turno al aire."""
    token = request.args.get("token") or (request.get_json(silent=True) or {}).get("token", "")
    if not token:
        return jsonify({"error": "token requerido"}), 400
    db = get_db()
    try:
        part = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND access_token = ?", (eid, token)
        ).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404
        was_on_air = part["status"] == "on_air"
        if part["status"] in ("pending", "approved", "in_queue", "on_air"):
            db.execute(
                "UPDATE participants SET status = ?, queue_position = NULL"
                + (", turn_ended_at = CURRENT_TIMESTAMP" if was_on_air else "")
                + " WHERE id = ?",
                ("done" if was_on_air else "left", part["id"]),
            )
            _compact_queue(db, eid)
            _update_preconnect_flags(db, eid)
            db.commit()
            ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
            room_name = (ev and ev["livekit_room_name"]) or room_name_for_event(eid)
            identity = part["livekit_identity"] or f"participant_{part['id']}"
            try:
                lk_remove_participant(room_name, identity)
            except Exception:
                pass
        row = db.execute("SELECT * FROM participants WHERE id = ?", (part["id"],)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


# ── Host-only endpoints ──────────────────────────────────────────────

@bp.get("/api/events/<int:eid>/queue")
@require_auth
def get_queue(eid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        rows = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND status IN ('in_queue', 'on_air') ORDER BY queue_position ASC",
            (eid,),
        ).fetchall()
        return jsonify([_serialize_participant(r) for r in rows])
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/requests")
@require_auth
def get_requests(eid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        rows = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND status = 'pending' ORDER BY requested_at ASC",
            (eid,),
        ).fetchall()
        return jsonify([_serialize_participant(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/approve/<int:pid>")
@require_auth
def approve_participant(eid, pid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        part = db.execute("SELECT * FROM participants WHERE id = ? AND event_id = ?", (pid, eid)).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404
        if part["status"] != "pending":
            return jsonify({"error": "el participante no está pendiente"}), 400

        # Get max queue position
        mx = db.execute(
            "SELECT COALESCE(MAX(queue_position), 0) AS mx FROM participants WHERE event_id = ? AND status = 'in_queue'",
            (eid,),
        ).fetchone()["mx"]

        db.execute(
            "UPDATE participants SET status = 'in_queue', queue_position = ?, approved_at = CURRENT_TIMESTAMP WHERE id = ?",
            (mx + 1, pid),
        )
        _update_preconnect_flags(db, eid)
        db.commit()
        row = db.execute("SELECT * FROM participants WHERE id = ?", (pid,)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/reject/<int:pid>")
@require_auth
def reject_participant(eid, pid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        part = db.execute("SELECT * FROM participants WHERE id = ? AND event_id = ?", (pid, eid)).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404

        db.execute("UPDATE participants SET status = 'rejected' WHERE id = ?", (pid,))
        db.commit()
        row = db.execute("SELECT * FROM participants WHERE id = ?", (pid,)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/next")
@require_auth
def next_turn(eid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err

        room_name = ev["livekit_room_name"] or room_name_for_event(eid)

        # Mark current on_air as done
        current = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND status = 'on_air'",
            (eid,),
        ).fetchone()
        if current:
            db.execute(
                "UPDATE participants SET status = 'done', turn_ended_at = CURRENT_TIMESTAMP, queue_position = NULL WHERE id = ?",
                (current["id"],),
            )
            cur_identity = current["livekit_identity"] or f"participant_{current['id']}"
            update_participant_permissions(room_name, cur_identity, can_publish=False)

        # Get next in queue
        nxt = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND status = 'in_queue' ORDER BY queue_position ASC LIMIT 1",
            (eid,),
        ).fetchone()
        if not nxt:
            db.commit()
            return jsonify({"message": "no hay más participantes en la cola"})

        db.execute(
            "UPDATE participants SET status = 'on_air', turn_started_at = CURRENT_TIMESTAMP, queue_position = NULL WHERE id = ?",
            (nxt["id"],),
        )
        nxt_identity = nxt["livekit_identity"] or f"participant_{nxt['id']}"
        update_participant_permissions(room_name, nxt_identity, can_publish=True)

        _compact_queue(db, eid)
        _update_preconnect_flags(db, eid)
        db.commit()
        row = db.execute("SELECT * FROM participants WHERE id = ?", (nxt["id"],)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/skip/<int:pid>")
@require_auth
def skip_to_participant(eid, pid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err

        room_name = ev["livekit_room_name"] or room_name_for_event(eid)

        part = db.execute("SELECT * FROM participants WHERE id = ? AND event_id = ?", (pid, eid)).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404
        if part["status"] != "in_queue":
            return jsonify({"error": "el participante no está en la cola"}), 400

        # Mark current on_air as done
        current = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND status = 'on_air'",
            (eid,),
        ).fetchone()
        if current:
            db.execute(
                "UPDATE participants SET status = 'done', turn_ended_at = CURRENT_TIMESTAMP, queue_position = NULL WHERE id = ?",
                (current["id"],),
            )
            cur_identity = current["livekit_identity"] or f"participant_{current['id']}"
            update_participant_permissions(room_name, cur_identity, can_publish=False)

        db.execute(
            "UPDATE participants SET status = 'on_air', turn_started_at = CURRENT_TIMESTAMP, queue_position = NULL WHERE id = ?",
            (pid,),
        )
        part_identity = part["livekit_identity"] or f"participant_{pid}"
        update_participant_permissions(room_name, part_identity, can_publish=True)

        _compact_queue(db, eid)
        _update_preconnect_flags(db, eid)
        db.commit()
        row = db.execute("SELECT * FROM participants WHERE id = ?", (pid,)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.put("/api/events/<int:eid>/reorder")
@require_auth
def reorder_queue(eid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        data = request.get_json(silent=True) or {}
        pids = data.get("order", [])
        for i, pid in enumerate(pids, 1):
            db.execute(
                "UPDATE participants SET queue_position = ? WHERE id = ? AND event_id = ? AND status = 'in_queue'",
                (i, pid, eid),
            )
        _update_preconnect_flags(db, eid)
        db.commit()
        rows = db.execute(
            "SELECT * FROM participants WHERE event_id = ? AND status = 'in_queue' ORDER BY queue_position ASC",
            (eid,),
        ).fetchall()
        return jsonify([_serialize_participant(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/censor/<int:pid>")
@require_auth
def censor_participant(eid, pid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        part = db.execute("SELECT * FROM participants WHERE id = ? AND event_id = ?", (pid, eid)).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404

        db.execute("UPDATE participants SET is_censored = 1 WHERE id = ?", (pid,))
        db.commit()

        # Mute + revoke publish in LiveKit
        room_name = ev["livekit_room_name"]
        identity = part["livekit_identity"] or f"participant_{pid}"
        if room_name:
            mute_participant(room_name, identity, muted=True)
            update_participant_permissions(room_name, identity, can_publish=False)

        row = db.execute("SELECT * FROM participants WHERE id = ?", (pid,)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/uncensor/<int:pid>")
@require_auth
def uncensor_participant(eid, pid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        part = db.execute("SELECT * FROM participants WHERE id = ? AND event_id = ?", (pid, eid)).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404

        db.execute("UPDATE participants SET is_censored = 0 WHERE id = ?", (pid,))
        db.commit()

        room_name = ev["livekit_room_name"]
        identity = part["livekit_identity"] or f"participant_{pid}"
        if room_name:
            mute_participant(room_name, identity, muted=False)
            update_participant_permissions(room_name, identity, can_publish=True)

        row = db.execute("SELECT * FROM participants WHERE id = ?", (pid,)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.delete("/api/events/<int:eid>/remove/<int:pid>")
@require_auth
def remove_from_queue(eid, pid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        part = db.execute("SELECT * FROM participants WHERE id = ? AND event_id = ?", (pid, eid)).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404

        db.execute("UPDATE participants SET status = 'left', queue_position = NULL WHERE id = ?", (pid,))
        _compact_queue(db, eid)
        _update_preconnect_flags(db, eid)
        db.commit()

        # Remove from LiveKit room
        room_name = ev["livekit_room_name"] or room_name_for_event(eid)
        identity = part["livekit_identity"] or f"participant_{pid}"
        lk_remove_participant(room_name, identity)

        return jsonify({"ok": True})
    finally:
        db.close()


# ── LiveKit token endpoints ──────────────────────────────────────────

@bp.get("/api/events/<int:eid>/host-token")
@require_auth
def host_token(eid):
    db = get_db()
    try:
        ev, err = _require_host(db, eid)
        if err:
            return err
        room_name = ev["livekit_room_name"] or room_name_for_event(eid)
        host = current_user()
        token = generate_participant_token(room_name, f"host_{host}", host, is_host=True)
        return jsonify({"token": token, "room_name": room_name})
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/participant-token/<int:pid>")
def participant_token(eid, pid):
    access_token = request.args.get("token", "")
    if not access_token:
        return jsonify({"error": "token requerido"}), 400

    db = get_db()
    try:
        part = db.execute(
            "SELECT * FROM participants WHERE id = ? AND event_id = ? AND access_token = ?",
            (pid, eid, access_token),
        ).fetchone()
        if not part:
            return jsonify({"error": "participante no encontrado"}), 404

        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404

        room_name = ev["livekit_room_name"] or room_name_for_event(eid)
        identity = f"participant_{pid}"
        can_publish = part["status"] in ("on_air",) and not part["is_censored"]

        db.execute("UPDATE participants SET livekit_identity = ? WHERE id = ?", (identity, pid))
        db.commit()

        token = generate_participant_token(
            room_name, identity, part["display_name"],
            is_host=False, can_publish=can_publish,
        )
        return jsonify({"token": token, "room_name": room_name})
    finally:
        db.close()
