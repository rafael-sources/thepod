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
from livekit_service import egress_info, start_rtmp_egress, stop_egress


bp = Blueprint("streams_api", __name__)


def _is_director(db, sid, username):
    p = db.execute(
        "SELECT role FROM participants WHERE session_id=? AND username=? AND role='director'",
        (sid, username),
    ).fetchone()
    return bool(p)


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


_FAILED_MSG = ("La transmisión se cortó o la plataforma no la aceptó. Revisa la clave de transmisión "
               "y que el directo esté habilitado en tu canal, y vuelve a empezar.")


def _refresh_live(db, rows):
    """Streams marked as active are confirmed with LiveKit: if the platform
    rejected it (bad key, live streaming not enabled) or it dropped, it is flagged with the reason.
    Previously they stayed "active" forever and nobody noticed."""
    changed = False
    for r in rows:
        if r["status"] not in ("starting", "active") or not r["egress_id"]:
            continue
        info = egress_info(r["egress_id"])
        if info is None:
            continue
        status, err, dests = info
        if status in ("EGRESS_FAILED", "EGRESS_ABORTED", "EGRESS_LIMIT_REACHED") or (dests and all(d == "FAILED" for d in dests)):
            db.execute("UPDATE live_streams SET status='failed', error=?, stopped_at=datetime('now') WHERE id=?",
                       (_FAILED_MSG, r["id"]))
            if status == "EGRESS_ACTIVE":
                stop_egress(r["egress_id"])
            changed = True
        elif status in ("EGRESS_COMPLETE",):
            db.execute("UPDATE live_streams SET status='stopped', stopped_at=datetime('now') WHERE id=?", (r["id"],))
            changed = True
    if changed:
        db.commit()
    return changed


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
        username = current_user()
        if sess["created_by"] != username and not _is_director(db, sid, username):
            return jsonify({"error": "sólo el host puede ver streams"}), 403
        rows = db.execute(
            "SELECT * FROM live_streams WHERE session_id=? ORDER BY id DESC", (sid,)
        ).fetchall()
        if _refresh_live(db, rows):
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
        username = current_user()
        if sess["created_by"] != username and not _is_director(db, sid, username):
            return jsonify({"error": "sólo el host puede iniciar streams"}), 403

        data = request.get_json(silent=True) or {}
        layout = (data.get("layout") or "grid").strip()

        # Accept either a single {rtmp_url, stream_key, platform} OR a list
        # of `destinations: [{rtmp_url, stream_key, platform}, ...]` for
        # multi-platform simultaneous streaming (YouTube + Twitch + …).
        raw_dests = data.get("destinations")
        if not raw_dests:
            raw_dests = [{
                "rtmp_url":   data.get("rtmp_url"),
                "stream_key": data.get("stream_key"),
                "platform":   data.get("platform"),
            }]
        if not isinstance(raw_dests, list) or not raw_dests:
            return jsonify({"error": "destinations debe ser una lista no vacía"}), 400

        full_urls = []
        normalized = []
        for d in raw_dests:
            url = (d.get("rtmp_url") or "").strip()
            key = (d.get("stream_key") or "").strip()
            plat = (d.get("platform") or "").strip().lower() or None
            if not url or not key:
                return jsonify({"error": "cada destination necesita rtmp_url y stream_key"}), 400
            if not url.startswith(("rtmp://", "rtmps://")):
                return jsonify({"error": "rtmp_url debe empezar con rtmp:// o rtmps://"}), 400
            full_urls.append(_rtmp_destination(url, key))
            normalized.append({"rtmp_url": url, "stream_key": key, "platform": plat})

        room_name = sess["livekit_room_name"]
        primary = normalized[0]

        # Persist one "primary" row + reference to all destinations so we can
        # show them in the UI; backend egress is a single multi-output egress.
        import json as _json
        cur = db.execute(
            """
            INSERT INTO live_streams (session_id, platform, rtmp_url, stream_key,
                                      status, started_by)
            VALUES (?, ?, ?, ?, 'starting', ?)
            """,
            (sid, primary["platform"], primary["rtmp_url"], primary["stream_key"], current_user()),
        )
        db.commit()
        stream_id = cur.lastrowid

        info = start_rtmp_egress(room_name, full_urls, layout=layout)
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
        username = current_user()
        if sess["created_by"] != username and not _is_director(db, sid, username):
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
