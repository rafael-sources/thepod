"""
RTMP live-streaming via LiveKit Egress. The host (session creator) can open
one or more Room Composite egresses that push a grid of the session to YouTube
Live / Twitch / any RTMP ingest.
"""

from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from auth import current_user, require_auth
from config import RTMP_PRESETS
from db import get_db
from livekit_service import start_rtmp_egress, stop_egress


bp = Blueprint("streams_api", __name__)


def _rtmp_destination(rtmp_url: str, stream_key: str) -> str:
    """Join base RTMP URL + key, tolerating trailing slash on the URL."""
    return rtmp_url.rstrip("/") + "/" + stream_key.lstrip("/")


def _serialize_stream(row):
    return {
        "id": row["id"],
        "session_id": row["session_id"],
        "platform": row["platform"],
        "rtmp_url": row["rtmp_url"],
        "egress_id": row["egress_id"],
        "status": row["status"],
        "started_by": row["started_by"],
        "started_at": row["started_at"],
        "stopped_at": row["stopped_at"],
        "error": row["error"],
    }


@bp.get("/api/rtmp-presets")
@require_auth
def list_rtmp_presets():
    return jsonify(RTMP_PRESETS)


@bp.get("/api/sessions/<int:sid>/streams")
@require_auth
def list_streams(sid):
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        if sess["created_by"] != current_user():
            return jsonify({"error": "sólo el host puede ver streams"}), 403
        rows = db.execute(
            "SELECT * FROM live_streams WHERE session_id=? ORDER BY id DESC", (sid,)
        ).fetchall()
        return jsonify([_serialize_stream(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/streams")
@require_auth
def create_stream(sid):
    """
    Start an RTMP egress pushing the session's room composite to the given
    ingest URL + stream key.

    JSON body:
      platform     (optional): "youtube", "twitch", etc. — used for labeling
      rtmp_url     (required): e.g. "rtmp://a.rtmp.youtube.com/live2/"
      stream_key   (required): the channel's stream key from the platform
      layout       (optional): "grid" (default) | "speaker"
    """
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        if sess["created_by"] != current_user():
            return jsonify({"error": "sólo el host puede iniciar streams"}), 403

        data = request.get_json(silent=True) or {}
        platform = (data.get("platform") or "").strip().lower() or None
        rtmp_url = (data.get("rtmp_url") or "").strip()
        stream_key = (data.get("stream_key") or "").strip()
        layout = (data.get("layout") or "grid").strip()

        if not rtmp_url or not stream_key:
            return jsonify({"error": "rtmp_url y stream_key requeridos"}), 400
        if not rtmp_url.startswith(("rtmp://", "rtmps://")):
            return jsonify({"error": "rtmp_url debe empezar con rtmp:// o rtmps://"}), 400

        destination = _rtmp_destination(rtmp_url, stream_key)
        room_name = sess["livekit_room_name"]

        # Persist as "starting" first so we have a DB row even if the egress
        # call fails. Update on return.
        cur = db.execute(
            """
            INSERT INTO live_streams (session_id, platform, rtmp_url, stream_key,
                                      status, started_by)
            VALUES (?, ?, ?, ?, 'starting', ?)
            """,
            (sid, platform, rtmp_url, stream_key, current_user()),
        )
        db.commit()
        stream_id = cur.lastrowid

        info = start_rtmp_egress(room_name, [destination], layout=layout)
        if info is None:
            db.execute(
                "UPDATE live_streams SET status='failed', error=?, stopped_at=datetime('now') WHERE id=?",
                ("LiveKit egress no respondió (¿servicio caído? ¿room vacío?)", stream_id),
            )
            db.commit()
            row = db.execute("SELECT * FROM live_streams WHERE id=?", (stream_id,)).fetchone()
            return jsonify({"error": "egress no inició", "stream": _serialize_stream(row)}), 502

        db.execute(
            "UPDATE live_streams SET egress_id=?, status='active' WHERE id=?",
            (info.egress_id, stream_id),
        )
        db.commit()
        row = db.execute("SELECT * FROM live_streams WHERE id=?", (stream_id,)).fetchone()
        return jsonify(_serialize_stream(row)), 201
    finally:
        db.close()


@bp.delete("/api/sessions/<int:sid>/streams/<int:stream_id>")
@require_auth
def stop_stream(sid, stream_id):
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        if sess["created_by"] != current_user():
            return jsonify({"error": "sólo el host puede detener streams"}), 403

        row = db.execute(
            "SELECT * FROM live_streams WHERE id=? AND session_id=?", (stream_id, sid),
        ).fetchone()
        if not row:
            return jsonify({"error": "stream no encontrado"}), 404

        if row["egress_id"] and row["status"] in ("starting", "active"):
            stop_egress(row["egress_id"])
        db.execute(
            "UPDATE live_streams SET status='stopped', stopped_at=datetime('now') WHERE id=?",
            (stream_id,),
        )
        db.commit()
        row = db.execute("SELECT * FROM live_streams WHERE id=?", (stream_id,)).fetchone()
        return jsonify(_serialize_stream(row))
    finally:
        db.close()
