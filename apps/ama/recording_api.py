"""Recording API blueprint — start/stop egress recording for amaPod events."""

import os
from flask import Blueprint, jsonify, send_file

from auth import require_auth, current_user
from db import get_db, event_dir
from livekit_service import (
    start_recording_egress,
    stop_egress,
    room_name_for_event,
)

bp = Blueprint("recording_api", __name__)


@bp.post("/api/events/<int:eid>/recording/start")
@require_auth
def start_recording(eid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if ev["status"] != "active":
            return jsonify({"error": "el evento debe estar activo para grabar"}), 400
        if ev["egress_id"]:
            return jsonify({"error": "ya hay una grabación en curso"}), 409

        room_name = ev["livekit_room_name"] or room_name_for_event(eid)
        edir = event_dir(eid)
        output_path = str(edir / "recordings" / f"event_{eid}.mp4")

        result = start_recording_egress(room_name, output_path)
        egress_id = getattr(result, "egress_id", None) if result else None

        if egress_id:
            db.execute(
                "UPDATE events SET egress_id = ?, recording_file = ? WHERE id = ?",
                (egress_id, output_path, eid),
            )
            db.commit()

        return jsonify({"egress_id": egress_id, "recording_file": output_path})
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/recording/stop")
@require_auth
def stop_recording(eid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if not ev["egress_id"]:
            return jsonify({"error": "no hay grabación en curso"}), 400

        stop_egress(ev["egress_id"])
        recording_file = ev["recording_file"]

        db.execute(
            "UPDATE events SET egress_id = NULL WHERE id = ?",
            (eid,),
        )
        db.commit()

        return jsonify({"recording_file": recording_file, "stopped": True})
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/recording/status")
@require_auth
def recording_status(eid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404

        recording = bool(ev["egress_id"])
        return jsonify({
            "recording": recording,
            "egress_id": ev["egress_id"],
            "recording_file": ev["recording_file"],
        })
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/recording/download")
@require_auth
def download_recording(eid):
    db = get_db()
    try:
        ev = db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if not ev["recording_file"] or not os.path.isfile(ev["recording_file"]):
            return jsonify({"error": "archivo de grabación no disponible"}), 404

        return send_file(ev["recording_file"], mimetype="video/mp4", as_attachment=True)
    finally:
        db.close()
