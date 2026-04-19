"""
Incoming integrations from prePod / postPod. Uses X-PodPod-Secret header,
same shared INTEGRATION_SECRET as the other apps.
"""

import secrets
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from config import INTEGRATION_SECRET, MAX_SESSION_PARTICIPANTS, USER_PROFILES
from db import get_db
from livekit_service import create_room, room_name_for_session


bp = Blueprint("integrations", __name__)


def _require_shared_secret():
    got = (request.headers.get("X-PodPod-Secret")
           or request.headers.get("Authorization", "").removeprefix("Bearer ").strip())
    if got != INTEGRATION_SECRET:
        return jsonify({"error": "no autorizado"}), 401
    return None


def _find_session_by_shared_id(db, shared_project_id):
    return db.execute(
        "SELECT * FROM sessions WHERE shared_project_id=?", (shared_project_id,)
    ).fetchone()


def _summarize_session(row):
    if not row:
        return None
    return {
        "id": row["id"],
        "title": row["title"],
        "status": row["status"],
        "shared_project_id": row["shared_project_id"],
        "livekit_room_name": row["livekit_room_name"],
        "created_at": row["created_at"],
    }


@bp.get("/api/integrations/status")
def integration_status():
    err = _require_shared_secret()
    if err:
        return err
    spid = request.args.get("shared_project_id")
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400
    db = get_db()
    try:
        row = _find_session_by_shared_id(db, spid)
        if not row:
            return jsonify({"found": False}), 404
        return jsonify({"found": True, "project": _summarize_session(row)})
    finally:
        db.close()


@bp.post("/api/integrations/prepod/import")
def import_from_prepod():
    """
    Create a prodPod recording session from a prePod episode payload.
    Idempotent on shared_project_id.
    """
    err = _require_shared_secret()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    if (data.get("source_app") or "").lower() != "prepod":
        return jsonify({"error": "source_app inválido"}), 400

    spid = data.get("shared_project_id")
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400

    podcast = data.get("podcast") or {}
    episode = data.get("episode") or {}

    podcast_name = (podcast.get("name") or "").strip() or "Podcast"
    ep_num = episode.get("number")
    ep_title = (episode.get("title") or "").strip()
    if ep_num and ep_title:
        session_title = f"{podcast_name} · Ep {ep_num}: {ep_title}"
    elif ep_title:
        session_title = f"{podcast_name} · {ep_title}"
    else:
        session_title = podcast_name

    db = get_db()
    try:
        existing = _find_session_by_shared_id(db, spid)
        if existing:
            return jsonify({"project": _summarize_session(existing), "created": False}), 200

        # Description: short excerpt of the script if available
        script = episode.get("script") or []
        if script:
            first_sections = script[:3]
            desc_lines = []
            for s in first_sections:
                speaker = s.get("speaker") or ""
                content = (s.get("content") or "").strip()
                if content:
                    desc_lines.append(f"{speaker}: {content[:120]}")
            description = "\n".join(desc_lines)
        else:
            description = (episode.get("description") or "").strip()

        # Creator: first user in USER_PROFILES (host by convention)
        creator = next(iter(USER_PROFILES.keys()), "admin")

        cur = db.execute(
            """
            INSERT INTO sessions (title, description, max_participants,
                                  created_by, shared_project_id, status)
            VALUES (?, ?, ?, ?, ?, 'preparing')
            """,
            (session_title, description, MAX_SESSION_PARTICIPANTS, creator, spid),
        )
        sid = cur.lastrowid
        room_name = room_name_for_session(sid)
        db.execute("UPDATE sessions SET livekit_room_name=? WHERE id=?", (room_name, sid))

        # Host participant
        host_token = secrets.token_urlsafe(32)
        host_profile = USER_PROFILES.get(creator, {})
        db.execute(
            "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
            "VALUES (?, ?, ?, ?, 'host', 'invited')",
            (sid, creator, host_profile.get("display_name", creator), host_token),
        )

        # Default soundboard
        from config import DEFAULT_SOUNDS
        for s in DEFAULT_SOUNDS:
            db.execute(
                "INSERT INTO sound_effects (session_id, name, filename, shortcut_key, color, is_default) "
                "VALUES (?, ?, ?, ?, ?, 1)",
                (sid, s["name"], s["filename"], s["key"], s["color"]),
            )

        db.commit()
        create_room(room_name, max_participants=MAX_SESSION_PARTICIPANTS)

        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return jsonify({"project": _summarize_session(row), "created": True}), 201
    finally:
        db.close()
