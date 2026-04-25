"""
Sessions CRUD + start/stop recording + participants + invitations.
"""

import secrets
from datetime import datetime, timezone

from flask import Blueprint, abort, jsonify, request

from auth import current_user, require_auth
from config import (
    DEFAULT_SOUNDS,
    LIVEKIT_WS_URL,
    MAX_SESSION_PARTICIPANTS,
    PARTICIPANT_ROLES,
    SESSION_STATUSES,
    USER_PROFILES,
)
from db import get_db
from livekit_service import (
    create_room,
    delete_room,
    generate_participant_token,
    room_name_for_session,
)


bp = Blueprint("sessions_api", __name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _serialize_session(row):
    return {
        "id": row["id"],
        "title": row["title"],
        "description": row["description"] or "",
        "status": row["status"],
        "max_participants": row["max_participants"],
        "created_by": row["created_by"],
        "shared_project_id": row["shared_project_id"],
        "livekit_room_name": row["livekit_room_name"],
        "started_at": row["started_at"],
        "finished_at": row["finished_at"],
        "total_duration_seconds": row["total_duration_seconds"],
        "is_public": bool(row["is_public"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _serialize_participant(row):
    return {
        "id": row["id"],
        "session_id": row["session_id"],
        "username": row["username"],
        "display_name": row["display_name"],
        "role": row["role"],
        "status": row["status"],
        "joined_at": row["joined_at"],
        "left_at": row["left_at"],
        "is_muted": bool(row["is_muted"]),
        "is_camera_off": bool(row["is_camera_off"]),
        "avatar_color": (USER_PROFILES.get(row["username"]) or {}).get("avatar_color", "#c7b894"),
    }


def _load_session(db, sid):
    row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
    if not row:
        abort(404, description="sesión no encontrada")
    return row


def _is_host(db, sid, username):
    row = db.execute("SELECT created_by FROM sessions WHERE id=?", (sid,)).fetchone()
    if not row:
        return False
    if row["created_by"] == username:
        return True
    p = db.execute(
        "SELECT role FROM participants WHERE session_id=? AND username=?",
        (sid, username),
    ).fetchone()
    return bool(p and p["role"] in ("host", "co-host"))


# ---------------------------------------------------------------------------
# Sessions CRUD
# ---------------------------------------------------------------------------

@bp.get("/api/sessions")
@require_auth
def list_sessions():
    db = get_db()
    try:
        username = current_user()
        rows = db.execute("""
            SELECT DISTINCT s.* FROM sessions s
            LEFT JOIN participants p ON p.session_id = s.id
            WHERE s.created_by = ?
               OR p.username    = ?
               OR s.is_public   = 1
            ORDER BY s.created_at DESC
        """, (username, username)).fetchall()

        # Ask LiveKit who is actually connected right now, so the UI can
        # show "Admin está dentro" instead of guessing from DB state.
        from livekit_service import list_participants
        out = []
        for r in rows:
            data = _serialize_session(r)
            try:
                live = list_participants(r["livekit_room_name"]) if r["livekit_room_name"] else []
                data["live_participants"] = [p.name or p.identity for p in live]
            except Exception:
                data["live_participants"] = []
            out.append(data)
        return jsonify(out)
    finally:
        db.close()


@bp.post("/api/sessions")
@require_auth
def create_session_endpoint():
    data = request.get_json(silent=True) or {}
    title = (data.get("title") or "").strip()
    if not title:
        return jsonify({"error": "title requerido"}), 400

    username = current_user()
    # Floor the max so there's always room for all known users + 2 invited
    # guests — otherwise the invite endpoint returns 409 "sesión llena".
    min_capacity = len(USER_PROFILES) + 2
    max_parts = max(
        min_capacity,
        min(int(data.get("max_participants", MAX_SESSION_PARTICIPANTS)), MAX_SESSION_PARTICIPANTS),
    )

    db = get_db()
    try:
        cur = db.execute(
            """
            INSERT INTO sessions (title, description, max_participants, created_by, shared_project_id)
            VALUES (?, ?, ?, ?, ?)
            """,
            (title, data.get("description") or "", max_parts, username, data.get("shared_project_id")),
        )
        sid = cur.lastrowid
        room_name = room_name_for_session(sid)
        db.execute("UPDATE sessions SET livekit_room_name=? WHERE id=?", (room_name, sid))

        # Host as participant #1
        host_token = secrets.token_urlsafe(32)
        host_profile = USER_PROFILES.get(username, {})
        db.execute(
            """
            INSERT INTO participants
                (session_id, username, display_name, invite_token, role, status)
            VALUES (?, ?, ?, ?, 'host', 'invited')
            """,
            (sid, username, host_profile.get("display_name", username), host_token),
        )
        # Every other known user gets auto-added as co-host so they can see
        # the session in their list and join without invite link friction.
        for other_user, profile in USER_PROFILES.items():
            if other_user == username:
                continue
            db.execute(
                """
                INSERT INTO participants
                    (session_id, username, display_name, invite_token, role, status)
                VALUES (?, ?, ?, ?, 'co-host', 'invited')
                """,
                (sid, other_user,
                 profile.get("display_name", other_user),
                 secrets.token_urlsafe(32)),
            )

        # Default soundboard
        for s in DEFAULT_SOUNDS:
            db.execute(
                "INSERT INTO sound_effects (session_id, name, filename, shortcut_key, color, is_default) "
                "VALUES (?, ?, ?, ?, ?, 1)",
                (sid, s["name"], s["filename"], s["key"], s["color"]),
            )

        db.commit()

        # Best-effort LiveKit room creation
        create_room(room_name, max_participants=max_parts)

        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return jsonify(_serialize_session(row)), 201
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>")
@require_auth
def get_session(sid):
    db = get_db()
    try:
        row = _load_session(db, sid)
        return jsonify(_serialize_session(row))
    finally:
        db.close()


@bp.put("/api/sessions/<int:sid>")
@require_auth
def update_session(sid):
    data = request.get_json(silent=True) or {}
    db = get_db()
    try:
        row = _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede editar"}), 403

        allowed = {"title", "description", "status", "max_participants", "is_public"}
        updates = {k: v for k, v in data.items() if k in allowed}
        if "status" in updates and updates["status"] not in SESSION_STATUSES:
            return jsonify({"error": f"status inválido: {updates['status']}"}), 400
        if "is_public" in updates:
            updates["is_public"] = 1 if updates["is_public"] else 0
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400

        cols = ", ".join(f"{k}=?" for k in updates) + ", updated_at=datetime('now')"
        db.execute(f"UPDATE sessions SET {cols} WHERE id=?", list(updates.values()) + [sid])
        db.commit()

        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return jsonify(_serialize_session(row))
    finally:
        db.close()


@bp.delete("/api/sessions/<int:sid>")
@require_auth
def delete_session(sid):
    db = get_db()
    try:
        row = _load_session(db, sid)
        if row["created_by"] != current_user():
            return jsonify({"error": "solo el creador puede eliminar"}), 403
        db.execute("DELETE FROM sessions WHERE id=?", (sid,))
        db.commit()
    finally:
        db.close()
    if row["livekit_room_name"]:
        delete_room(row["livekit_room_name"])
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Start / stop recording (state only — real egress comes in Plan 2)
# ---------------------------------------------------------------------------

@bp.post("/api/sessions/<int:sid>/start")
@require_auth
def start_recording(sid):
    db = get_db()
    try:
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede iniciar la grabación"}), 403
        db.execute(
            "UPDATE sessions SET status='recording', started_at=datetime('now'), updated_at=datetime('now') "
            "WHERE id=?",
            (sid,),
        )
        db.commit()
        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return jsonify(_serialize_session(row))
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/stop")
@require_auth
def stop_recording(sid):
    db = get_db()
    try:
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede detener la grabación"}), 403
        db.execute(
            "UPDATE sessions SET status='finished', finished_at=datetime('now'), updated_at=datetime('now') "
            "WHERE id=?",
            (sid,),
        )
        db.commit()
        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        return jsonify(_serialize_session(row))
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Participants
# ---------------------------------------------------------------------------

@bp.get("/api/sessions/<int:sid>/participants")
@require_auth
def list_participants(sid):
    db = get_db()
    try:
        _load_session(db, sid)
        rows = db.execute(
            "SELECT * FROM participants WHERE session_id=? ORDER BY id", (sid,)
        ).fetchall()
        return jsonify([_serialize_participant(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/invite")
@require_auth
def create_invite(sid):
    data = request.get_json(silent=True) or {}
    display_name = (data.get("display_name") or "Invitado").strip()
    role = data.get("role", "guest")
    if role not in PARTICIPANT_ROLES:
        return jsonify({"error": f"role inválido: {role}"}), 400

    db = get_db()
    try:
        _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede invitar"}), 403

        count = db.execute(
            "SELECT COUNT(*) AS n FROM participants WHERE session_id=?", (sid,)
        ).fetchone()["n"]
        limit = db.execute("SELECT max_participants FROM sessions WHERE id=?", (sid,)).fetchone()["max_participants"]
        if count >= limit:
            return jsonify({"error": f"sesión llena (máx {limit})"}), 409

        token = secrets.token_urlsafe(32)
        cur = db.execute(
            "INSERT INTO participants (session_id, display_name, invite_token, role) "
            "VALUES (?, ?, ?, ?)",
            (sid, display_name, token, role),
        )
        db.commit()
        return jsonify({
            "id": cur.lastrowid,
            "invite_token": token,
            "invite_url": f"{request.host_url.rstrip('/')}/invite/{token}",
        }), 201
    finally:
        db.close()


@bp.delete("/api/sessions/<int:sid>/participants/<int:pid>")
@require_auth
def remove_participant(sid, pid):
    db = get_db()
    try:
        _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede remover"}), 403
        db.execute("DELETE FROM participants WHERE id=? AND session_id=?", (pid, sid))
        db.commit()
    finally:
        db.close()
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Chat messages (persisted — live delivery happens via WebRTC data channel)
# ---------------------------------------------------------------------------

@bp.get("/api/sessions/<int:sid>/chat")
@require_auth
def list_chat(sid):
    db = get_db()
    try:
        _load_session(db, sid)
        rows = db.execute(
            "SELECT id, author_name, participant_id, message_text, timestamp "
            "FROM chat_messages WHERE session_id=? ORDER BY id",
            (sid,),
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/chat")
@require_auth
def post_chat(sid):
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify({"error": "text requerido"}), 400
    if len(text) > 2000:
        return jsonify({"error": "text muy largo"}), 400

    username = current_user()
    db = get_db()
    try:
        _load_session(db, sid)
        p = db.execute(
            "SELECT id, display_name FROM participants WHERE session_id=? AND username=?",
            (sid, username),
        ).fetchone()
        author = (p["display_name"] if p else None) or (USER_PROFILES.get(username) or {}).get("display_name", username)
        cur = db.execute(
            "INSERT INTO chat_messages (session_id, participant_id, author_name, message_text) "
            "VALUES (?, ?, ?, ?)",
            (sid, p["id"] if p else None, author, text),
        )
        db.commit()
        row = db.execute("SELECT * FROM chat_messages WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(dict(row)), 201
    finally:
        db.close()


@bp.post("/api/invite/<token>/chat")
def post_chat_guest(token):
    """Guests (invited participants) can also post chat using their invite token."""
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify({"error": "text requerido"}), 400
    db = get_db()
    try:
        p = db.execute(
            "SELECT id, session_id, display_name FROM participants WHERE invite_token=?",
            (token,),
        ).fetchone()
        if not p:
            return jsonify({"error": "token inválido"}), 401
        cur = db.execute(
            "INSERT INTO chat_messages (session_id, participant_id, author_name, message_text) "
            "VALUES (?, ?, ?, ?)",
            (p["session_id"], p["id"], p["display_name"], text),
        )
        db.commit()
        row = db.execute("SELECT * FROM chat_messages WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(dict(row)), 201
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Soundboard
# ---------------------------------------------------------------------------

@bp.get("/api/sessions/<int:sid>/sounds")
@require_auth
def list_sounds(sid):
    db = get_db()
    try:
        _load_session(db, sid)
        rows = db.execute(
            "SELECT id, name, filename, shortcut_key, color, duration_seconds, is_default "
            "FROM sound_effects WHERE session_id=? ORDER BY shortcut_key, id",
            (sid,),
        ).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            if d["is_default"]:
                d["url"] = f"/static/sounds/{d['filename']}"
            else:
                d["url"] = f"/api/sessions/{sid}/sounds/{d['filename']}"
            out.append(d)
        return jsonify(out)
    finally:
        db.close()


def _probe_audio_duration(path):
    import subprocess, json
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(path)],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            return None
        d = json.loads(r.stdout).get("format", {}).get("duration")
        return float(d) if d else None
    except Exception:
        return None


@bp.post("/api/sessions/<int:sid>/sounds/<int:sound_id>/upload")
@require_auth
def upload_sound(sid, sound_id):
    """Replace the audio file for a specific soundboard pad.
    Enforces MAX_SOUND_BYTES and MAX_SOUND_DURATION_SECONDS."""
    from config import ALLOWED_SOUND_EXTS, MAX_SOUND_BYTES, MAX_SOUND_DURATION_SECONDS
    import uuid
    from pathlib import Path

    db = get_db()
    try:
        _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede cambiar sonidos"}), 403
        row = db.execute(
            "SELECT * FROM sound_effects WHERE id=? AND session_id=?",
            (sound_id, sid),
        ).fetchone()
        if not row:
            return jsonify({"error": "sonido no encontrado"}), 404

        f = request.files.get("file")
        if not f or not f.filename:
            return jsonify({"error": "archivo requerido"}), 400
        ext = Path(f.filename).suffix.lower()
        if ext not in ALLOWED_SOUND_EXTS:
            return jsonify({
                "error": f"extensión no soportada: {ext} (usá mp3, wav, ogg o m4a)",
            }), 400

        from db import session_dir
        dest_dir = session_dir(sid) / "sounds"
        dest_dir.mkdir(parents=True, exist_ok=True)
        new_filename = f"sound_{sound_id}_{uuid.uuid4().hex[:8]}{ext}"
        dest = dest_dir / new_filename
        f.save(str(dest))

        size = dest.stat().st_size
        if size > MAX_SOUND_BYTES:
            try: dest.unlink()
            except OSError: pass
            max_kb = MAX_SOUND_BYTES // 1024
            return jsonify({
                "error": f"archivo muy grande: {size // 1024} KB (máx {max_kb} KB)",
            }), 413

        dur = _probe_audio_duration(dest)
        if dur is not None and dur > MAX_SOUND_DURATION_SECONDS:
            try: dest.unlink()
            except OSError: pass
            return jsonify({
                "error": f"duración {dur:.1f}s supera el máximo de {MAX_SOUND_DURATION_SECONDS}s",
            }), 413

        # Remove previous custom file (don't touch defaults in static/sounds)
        if not row["is_default"] and row["filename"]:
            old = dest_dir / row["filename"]
            if old.exists() and old != dest:
                try: old.unlink()
                except OSError: pass

        db.execute(
            "UPDATE sound_effects SET filename=?, is_default=0, duration_seconds=?, file_size_bytes=? WHERE id=?",
            (new_filename, dur, size, sound_id),
        )
        db.commit()
        return jsonify({
            "ok": True,
            "filename": new_filename,
            "duration_seconds": dur,
            "size_bytes": size,
            "url": f"/api/sessions/{sid}/sounds/{new_filename}",
        })
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>/sounds/limits")
@require_auth
def sound_limits(sid):
    from config import (ALLOWED_SOUND_EXTS, MAX_SOUND_BYTES,
                         MAX_SOUND_DURATION_SECONDS, MAX_SOUNDS_PER_SESSION)
    return jsonify({
        "max_bytes": MAX_SOUND_BYTES,
        "max_kb": MAX_SOUND_BYTES // 1024,
        "max_duration_seconds": MAX_SOUND_DURATION_SECONDS,
        "allowed_exts": sorted(ALLOWED_SOUND_EXTS),
        "max_total": MAX_SOUNDS_PER_SESSION,
    })


@bp.post("/api/sessions/<int:sid>/sounds")
@require_auth
def create_sound(sid):
    """Create a new custom pad (without a file yet — upload follows)."""
    from config import MAX_SOUNDS_PER_SESSION
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    key = (data.get("shortcut_key") or "").strip().upper()[:1]
    color = (data.get("color") or "#5a8bff").strip()
    if not name:
        return jsonify({"error": "nombre requerido"}), 400

    db = get_db()
    try:
        _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede agregar sonidos"}), 403

        n = db.execute(
            "SELECT COUNT(*) AS n FROM sound_effects WHERE session_id=?", (sid,)
        ).fetchone()["n"]
        if n >= MAX_SOUNDS_PER_SESSION:
            return jsonify({"error": f"máximo {MAX_SOUNDS_PER_SESSION} sonidos por sesión"}), 409

        # Conflict check on shortcut_key (nullable, just warn via frontend if already taken)
        cur = db.execute(
            "INSERT INTO sound_effects (session_id, name, filename, shortcut_key, color, is_default) "
            "VALUES (?, ?, '', ?, ?, 0)",
            (sid, name, key or None, color),
        )
        db.commit()
        row = db.execute("SELECT * FROM sound_effects WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify({
            "id": row["id"],
            "name": row["name"],
            "shortcut_key": row["shortcut_key"] or "",
            "color": row["color"],
            "filename": row["filename"],
            "url": None,
            "is_default": 0,
        }), 201
    finally:
        db.close()


@bp.delete("/api/sessions/<int:sid>/sounds/<int:sound_id>")
@require_auth
def delete_sound(sid, sound_id):
    """Delete a custom pad. Defaults can't be deleted (use /reset instead)."""
    db = get_db()
    try:
        _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede eliminar"}), 403
        row = db.execute(
            "SELECT * FROM sound_effects WHERE id=? AND session_id=?",
            (sound_id, sid),
        ).fetchone()
        if not row:
            return jsonify({"error": "sonido no encontrado"}), 404
        if row["is_default"]:
            return jsonify({"error": "no se pueden eliminar los sonidos por defecto (usá reset)"}), 400
        # Remove custom file
        from db import session_dir
        from pathlib import Path
        if row["filename"]:
            p = Path(session_dir(sid) / "sounds" / row["filename"])
            if p.exists():
                try: p.unlink()
                except OSError: pass
        db.execute("DELETE FROM sound_effects WHERE id=?", (sound_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/sounds/<int:sound_id>/reset")
@require_auth
def reset_sound(sid, sound_id):
    """Revert a pad to its default filename (doesn't delete the custom file, just re-points)."""
    from config import DEFAULT_SOUNDS
    db = get_db()
    try:
        _load_session(db, sid)
        if not _is_host(db, sid, current_user()):
            return jsonify({"error": "solo el host puede resetear"}), 403
        row = db.execute(
            "SELECT shortcut_key FROM sound_effects WHERE id=? AND session_id=?",
            (sound_id, sid),
        ).fetchone()
        if not row:
            return jsonify({"error": "sonido no encontrado"}), 404
        default = next((s for s in DEFAULT_SOUNDS if s["key"] == row["shortcut_key"]), None)
        if not default:
            return jsonify({"error": "sin default para esta tecla"}), 400
        db.execute(
            "UPDATE sound_effects SET filename=?, is_default=1 WHERE id=?",
            (default["filename"], sound_id),
        )
        db.commit()
        return jsonify({"ok": True, "url": f"/static/sounds/{default['filename']}"})
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>/sounds/<path:filename>")
@require_auth
def serve_custom_sound(sid, filename):
    """Serve a session-local custom sound file."""
    import os
    from flask import abort, send_from_directory
    from db import session_dir
    base = (session_dir(sid) / "sounds").resolve()
    target = (base / filename).resolve()
    if not str(target).startswith(str(base) + os.sep):
        abort(403)
    if not target.is_file():
        abort(404)
    return send_from_directory(str(base), filename)


# ---------------------------------------------------------------------------
# Public invite endpoints (no auth — link shared externally)
# ---------------------------------------------------------------------------

@bp.get("/api/invite/<token>")
def get_invite_details(token):
    db = get_db()
    try:
        p = db.execute(
            "SELECT p.*, s.title AS session_title, s.description AS session_description, "
            "       s.status AS session_status "
            "FROM participants p JOIN sessions s ON s.id = p.session_id "
            "WHERE p.invite_token=?",
            (token,),
        ).fetchone()
        if not p:
            return jsonify({"error": "invitación inválida"}), 404
        return jsonify({
            "participant_id": p["id"],
            "session_id": p["session_id"],
            "display_name": p["display_name"],
            "role": p["role"],
            "status": p["status"],
            "session_title": p["session_title"],
            "session_description": p["session_description"] or "",
            "session_status": p["session_status"],
        })
    finally:
        db.close()


@bp.post("/api/invite/<token>/join")
def join_with_invite(token):
    data = request.get_json(silent=True) or {}
    override_name = (data.get("display_name") or "").strip()

    db = get_db()
    try:
        p = db.execute(
            "SELECT p.*, s.livekit_room_name "
            "FROM participants p JOIN sessions s ON s.id = p.session_id "
            "WHERE p.invite_token=?",
            (token,),
        ).fetchone()
        if not p:
            return jsonify({"error": "invitación inválida"}), 404

        display_name = override_name or p["display_name"]
        if override_name and override_name != p["display_name"]:
            db.execute("UPDATE participants SET display_name=? WHERE id=?", (override_name, p["id"]))

        db.execute(
            "UPDATE participants SET status='connected', joined_at=datetime('now') WHERE id=?",
            (p["id"],),
        )
        db.commit()

        is_host = p["role"] in ("host", "co-host")
        token_jwt = generate_participant_token(
            room_name=p["livekit_room_name"],
            identity=f"participant_{p['id']}",
            display_name=display_name,
            is_host=is_host,
        )
        return jsonify({
            "participant_id": p["id"],
            "session_id": p["session_id"],
            "display_name": display_name,
            "role": p["role"],
            "livekit_ws_url": LIVEKIT_WS_URL,
            "livekit_token": token_jwt,
            "room_name": p["livekit_room_name"],
        })
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Host convenience: get own JWT without invite link
# ---------------------------------------------------------------------------

@bp.get("/api/sessions/<int:sid>/my-token")
@require_auth
def my_join_token(sid):
    username = current_user()
    db = get_db()
    try:
        row = _load_session(db, sid)
        p = db.execute(
            "SELECT * FROM participants WHERE session_id=? AND username=?",
            (sid, username),
        ).fetchone()
        if not p:
            return jsonify({"error": "no sos participante de esta sesión"}), 403
        db.execute(
            "UPDATE participants SET status='connected', joined_at=datetime('now') WHERE id=?",
            (p["id"],),
        )
        db.commit()
        is_host = p["role"] in ("host", "co-host")
        token_jwt = generate_participant_token(
            room_name=row["livekit_room_name"],
            identity=f"participant_{p['id']}",
            display_name=p["display_name"],
            is_host=is_host,
        )
        return jsonify({
            "participant_id": p["id"],
            "display_name": p["display_name"],
            "role": p["role"],
            "livekit_ws_url": LIVEKIT_WS_URL,
            "livekit_token": token_jwt,
            "room_name": row["livekit_room_name"],
        })
    finally:
        db.close()
