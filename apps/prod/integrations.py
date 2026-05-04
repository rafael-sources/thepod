"""
Incoming integrations from prePod / postPod. Uses X-PodPod-Secret header,
same shared INTEGRATION_SECRET as the other apps.
"""

import json as _json
import secrets
import urllib.error
import urllib.request
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request

from config import INTEGRATION_SECRET, MAX_SESSION_PARTICIPANTS, PARTICIPANT_ROLES, USER_PROFILES
from db import get_db, session_dir
from livekit_service import create_room, room_name_for_session
from shared_config import load_shared_config


def _public_base_url():
    """
    Prefer the explicitly-configured prodpod_url (from ~/.podpod/config.json)
    over request.host_url, because behind some reverse proxies request.host_url
    comes back as http:// even when the public origin is https://. Camera and
    microphone APIs are blocked by browsers on insecure origins, so the invite
    URL MUST point at the https origin.
    """
    cfg = load_shared_config()
    base = (cfg.get("prodpod_url") or "").rstrip("/")
    if base:
        return base
    return request.host_url.rstrip("/")


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

        # Creator: prefer the owner_username sent by prePod (so when Karelia
        # owns the podcast in prePod, she becomes the host of the prodPod
        # session too). Falls back to first known user.
        requested_owner = (data.get("owner_username") or "").strip().lower()
        if requested_owner and requested_owner in USER_PROFILES:
            creator = requested_owner
        else:
            creator = next(iter(USER_PROFILES.keys()), "admin")
        # Extra hosts coming from prePod's "Hosts" panel become co-hosts here.
        extra_hosts_in = data.get("extra_hosts") or []
        extra_co_hosts = [u for u in extra_hosts_in
                          if isinstance(u, str) and u.strip().lower() in USER_PROFILES
                          and u.strip().lower() != creator]

        source_url = (data.get("source_url") or "").rstrip("/") or None
        source_slug = (podcast.get("slug") or "").strip() or None
        source_episode_id = episode.get("id")

        cur = db.execute(
            """
            INSERT INTO sessions (title, description, max_participants,
                                  created_by, shared_project_id, status,
                                  source_url, source_slug, source_episode_id)
            VALUES (?, ?, ?, ?, ?, 'preparing', ?, ?, ?)
            """,
            (session_title, description, MAX_SESSION_PARTICIPANTS, creator, spid,
             source_url, source_slug, source_episode_id),
        )
        sid = cur.lastrowid
        room_name = room_name_for_session(sid)
        db.execute("UPDATE sessions SET livekit_room_name=? WHERE id=?", (room_name, sid))

        # Participants: ONLY the podcast owner (host) + the explicit extra
        # hosts that prePod sent. We do NOT auto-add other operators — even
        # admins — because their podcast is none of this episode's business.
        # If an admin needs to join post-hoc, my_join_token() in sessions_api
        # self-heals by inserting a co-host row on the fly.
        host_token = secrets.token_urlsafe(32)
        host_profile = USER_PROFILES.get(creator, {})
        db.execute(
            "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
            "VALUES (?, ?, ?, ?, 'host', 'invited')",
            (sid, creator, host_profile.get("display_name", creator), host_token),
        )
        already = {creator}
        for u in extra_co_hosts:
            if u in already:
                continue
            already.add(u)
            profile = USER_PROFILES.get(u, {})
            db.execute(
                "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
                "VALUES (?, ?, ?, ?, 'co-host', 'invited')",
                (sid, u, profile.get("display_name", u), secrets.token_urlsafe(32)),
            )

        # Soundboard: use prePod podcast preset if provided; otherwise the
        # built-in defaults.
        preset = podcast.get("sounds") or []
        installed_preset = 0
        if preset:
            sounds_dir = session_dir(sid) / "sounds"
            sounds_dir.mkdir(parents=True, exist_ok=True)
            for s in preset:
                url = (s.get("download_url") or "").strip()
                fname = (s.get("filename") or "").strip()
                if not url or not fname:
                    continue
                local = sounds_dir / fname
                try:
                    req = urllib.request.Request(
                        url, headers={"X-PodPod-Secret": INTEGRATION_SECRET}
                    )
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        local.write_bytes(resp.read())
                except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
                    continue
                db.execute(
                    "INSERT INTO sound_effects (session_id, name, filename, shortcut_key, color, "
                    "duration_seconds, file_size_bytes, is_default) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, 0)",
                    (sid, s.get("name") or fname, fname, s.get("shortcut_key"), s.get("color"),
                     s.get("duration_seconds"), s.get("file_size_bytes")),
                )
                installed_preset += 1

        if installed_preset == 0:
            from config import DEFAULT_SOUNDS
            for s in DEFAULT_SOUNDS:
                db.execute(
                    "INSERT INTO sound_effects (session_id, name, filename, shortcut_key, color, is_default) "
                    "VALUES (?, ?, ?, ?, ?, 1)",
                    (sid, s["name"], s["filename"], s["key"], s["color"]),
                )

        # Pre-populate planned chapter markers from prePod rundown blocks.
        # Use planned_offset_seconds from prePod when available; otherwise
        # accumulate duration estimates (stored in minutes) as fallback.
        cumulative_sec = 0.0
        for b in (episode.get("blocks") or []):
            label = (b.get("title") or b.get("kind") or "Bloque").strip()
            offset = b.get("planned_offset_seconds")
            if offset is not None:
                try:
                    offset = float(offset)
                except (TypeError, ValueError):
                    offset = cumulative_sec
            else:
                offset = cumulative_sec
            kind = b.get("kind") or "segment"
            sponsor_name = b.get("sponsor_name") or None
            sponsor_copy = b.get("sponsor_copy") or None
            sponsor_logo = b.get("sponsor_logo_url") or None
            db.execute(
                "INSERT INTO chapter_markers "
                "(session_id, label, tl_offset_seconds, is_planned, kind, "
                " sponsor_name, sponsor_copy, sponsor_logo_url, planned_offset_seconds) "
                "VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)",
                (sid, label, offset, kind,
                 sponsor_name, sponsor_copy, sponsor_logo, offset),
            )
            mins = b.get("duration_estimate")
            if mins:
                try:
                    cumulative_sec += float(mins) * 60.0
                except (TypeError, ValueError):
                    pass

        # Auto-create one participant + invite link per guest from prePod
        guest_invites = []
        for g in (episode.get("guests") or []):
            gname = (g.get("name") or "").strip()
            if not gname:
                continue
            grole = g.get("role") or "guest"
            if grole not in PARTICIPANT_ROLES:
                grole = "guest"
            gtoken = secrets.token_urlsafe(32)
            db.execute(
                "INSERT INTO participants (session_id, display_name, invite_token, role, status) "
                "VALUES (?, ?, ?, ?, 'invited')",
                (sid, gname, gtoken, grole),
            )
            guest_invites.append({
                "name": gname,
                "invite_token": gtoken,
                "invite_url": f"{_public_base_url()}/invite/{gtoken}",
            })

        db.commit()
        create_room(room_name, max_participants=MAX_SESSION_PARTICIPANTS)

        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return jsonify({
            "project": _summarize_session(row),
            "created": True,
            "guest_invites": guest_invites,
        }), 201
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Outbound: notify the originating prePod about lifecycle events
# ---------------------------------------------------------------------------

def notify_source(session_row, event: str, extra: dict | None = None, timeout: float = 5):
    """
    Fire-and-forget POST to {source_url}/api/integrations/prodpod/event with
    {event, slug, episode_id, session_id, ...extra}. Silently no-ops if the
    session has no recorded source. Errors are swallowed so production-side
    state changes never fail because of an offline prePod.
    """
    if not session_row:
        return
    src_url = session_row["source_url"] if "source_url" in session_row.keys() else None
    if not src_url:
        return
    payload = {
        "event": event,
        "session_id": session_row["id"],
        "slug": session_row["source_slug"],
        "episode_id": session_row["source_episode_id"],
        "shared_project_id": session_row["shared_project_id"],
        "session_status": session_row["status"],
        "occurred_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    if extra:
        payload.update(extra)
    body = _json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{src_url.rstrip('/')}/api/integrations/prodpod/event",
        data=body,
        headers={"Content-Type": "application/json", "X-PodPod-Secret": INTEGRATION_SECRET},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout):
            pass
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        # Source app is offline or rejected the event — production keeps going.
        pass
