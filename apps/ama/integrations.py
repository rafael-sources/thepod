"""Integrations blueprint — cross-app communication for the podpod suite."""

from flask import Blueprint, jsonify, request

from auth import require_auth, current_user
from config import INTEGRATION_SECRET, AMAPOD_URL
from db import get_db
from livekit_service import create_room, room_name_for_event

bp = Blueprint("integrations", __name__)


def _require_pod_secret():
    """Check X-PodPod-Secret header matches INTEGRATION_SECRET."""
    secret = request.headers.get("X-PodPod-Secret", "")
    if secret != INTEGRATION_SECRET:
        return False
    return True


@bp.post("/api/integrations/prodpod/create-event")
def create_event_from_prodpod():
    if not _require_pod_secret():
        return jsonify({"error": "secret inválido"}), 401

    data = request.get_json(silent=True) or {}
    title = data.get("title", "Evento desde prodPod")
    host_username = data.get("host_username", "admin")
    description = data.get("description", "")
    branding_json = data.get("branding_json")
    prodpod_session_id = data.get("prodpod_session_id")

    db = get_db()
    try:
        cur = db.execute(
            "INSERT INTO events (title, description, host_username, status, branding_json, prodpod_session_id) "
            "VALUES (?, ?, ?, 'active', ?, ?)",
            (title, description, host_username, branding_json, prodpod_session_id),
        )
        db.commit()
        eid = cur.lastrowid
        room_name = room_name_for_event(eid)
        create_room(room_name)
        db.execute(
            "UPDATE events SET livekit_room_name = ?, started_at = CURRENT_TIMESTAMP WHERE id = ?",
            (room_name, eid),
        )
        db.commit()

        embed_url = f"{AMAPOD_URL}/embed/{eid}"
        return jsonify({"event_id": eid, "embed_url": embed_url}), 201
    finally:
        db.close()


@bp.post("/api/integrations/postpod/export")
@require_auth
def export_to_postpod():
    data = request.get_json(silent=True) or {}
    eid = data.get("event_id")
    if not eid:
        return jsonify({"error": "event_id requerido"}), 400

    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404

        # Gather chat messages
        messages = db.execute(
            "SELECT * FROM chat_messages WHERE event_id = ? AND is_approved = 1 ORDER BY created_at ASC",
            (eid,),
        ).fetchall()

        export_data = {
            "event_id": eid,
            "title": ev["title"],
            "recording_file": ev["recording_file"],
            "chat_messages": [
                {
                    "sender_name": m["sender_name"],
                    "message": m["message"],
                    "is_host": m["is_host"],
                    "created_at": m["created_at"],
                }
                for m in messages
            ],
        }

        # In a real implementation, this would POST to postPod's API.
        # For now, return the data that would be sent.
        return jsonify({"exported": True, "data": export_data})
    finally:
        db.close()


@bp.post("/api/integrations/prepod/import")
def import_from_prepod():
    if not _require_pod_secret():
        return jsonify({"error": "secret inválido"}), 401

    # Stub: acknowledge the import request
    return jsonify({"ok": True, "message": "import stub"})
