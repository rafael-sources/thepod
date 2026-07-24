"""Integrations blueprint — cross-app communication for the podpod suite."""

import logging
import os
import uuid
from pathlib import Path

import requests as http_requests
from flask import Blueprint, jsonify, request

from auth import require_auth, current_user
from config import INTEGRATION_SECRET, AMAPOD_URL, POSTPOD_URL
from db import get_db
from livekit_service import create_room, room_name_for_event

log = logging.getLogger(__name__)

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

    result, status = _do_export_to_postpod(eid)
    return jsonify(result), status


def _do_export_to_postpod(eid):
    """Export recording to postPod. Returns (result_dict, status_code)."""
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return {"error": "evento no encontrado"}, 404

        recording_path = ev["recording_file"]
        if not recording_path or not os.path.isfile(recording_path):
            return {"error": "no hay archivo de grabacion disponible"}, 400

        spid = ev["shared_project_id"]
        if not spid:
            spid = uuid.uuid4().hex
            db.execute("UPDATE events SET shared_project_id = ? WHERE id = ?", (spid, eid))
            db.commit()

        endpoint = POSTPOD_URL.rstrip("/") + "/api/integrations/prodpod/import-track"
        headers = {"X-PodPod-Secret": INTEGRATION_SECRET}

        original_name = f"amapod_{ev['title']}_{eid}.mp4"
        try:
            with open(recording_path, "rb") as fh:
                resp = http_requests.post(
                    endpoint,
                    headers=headers,
                    data={
                        "shared_project_id": spid,
                        "original_name": original_name,
                        "track_type": "video",
                        "participant_name": ev["host_username"],
                        "project_name": ev["title"],
                        "owner_username": ev["host_username"],
                    },
                    files={"file": (original_name, fh, "video/mp4")},
                    timeout=120,
                )
            if resp.status_code not in (200, 201):
                log.warning("postPod export failed: %s %s", resp.status_code, resp.text[:200])
                return {"error": f"postPod respondio {resp.status_code}"}, 502

            return {"exported": True, "postpod_response": resp.json()}, 200
        except http_requests.RequestException as e:
            log.warning("postPod export request failed: %s", e)
            return {"error": str(e)}, 502
    finally:
        db.close()


@bp.post("/api/integrations/prepod/import")
def import_from_prepod():
    if not _require_pod_secret():
        return jsonify({"error": "secret inválido"}), 401

    # Stub: acknowledge the import request
    return jsonify({"ok": True, "message": "import stub"})
