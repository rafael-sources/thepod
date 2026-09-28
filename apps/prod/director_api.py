"""
Director module — API endpoints for overlay injection, asset upload,
director event management, and podcast-director assignments.
"""

import json
import secrets
from pathlib import Path

from flask import Blueprint, abort, jsonify, request

from auth import current_user, require_auth
from db import get_db, session_dir

bp = Blueprint("director_api", __name__)


def _is_director(db, sid, username):
    p = db.execute(
        "SELECT role FROM participants WHERE session_id=? AND username=? AND role='director'",
        (sid, username),
    ).fetchone()
    return bool(p)


def _require_director(db, sid):
    username = current_user()
    if not _is_director(db, sid, username):
        abort(403, description="solo el director puede realizar esta acción")
    return username


# ---------------------------------------------------------------------------
# Podcast director assignments
# ---------------------------------------------------------------------------

@bp.get("/api/podcast-directors/<shared_project_id>")
@require_auth
def list_podcast_directors(shared_project_id):
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM podcast_directors WHERE shared_project_id=?",
            (shared_project_id,),
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcast-directors/<shared_project_id>")
@require_auth
def assign_podcast_director(shared_project_id):
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    if not username:
        return jsonify({"error": "username requerido"}), 400
    db = get_db()
    try:
        db.execute(
            "INSERT OR IGNORE INTO podcast_directors (username, shared_project_id, assigned_by) VALUES (?, ?, ?)",
            (username, shared_project_id, current_user()),
        )
        db.commit()
        return jsonify({"ok": True}), 201
    finally:
        db.close()


@bp.delete("/api/podcast-directors/<shared_project_id>/<username>")
@require_auth
def remove_podcast_director(shared_project_id, username):
    db = get_db()
    try:
        db.execute(
            "DELETE FROM podcast_directors WHERE shared_project_id=? AND username=?",
            (shared_project_id, username),
        )
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Director join (self-heal into session as director)
# ---------------------------------------------------------------------------

@bp.get("/api/sessions/<int:sid>/director-token")
@require_auth
def director_join_token(sid):
    from livekit_service import generate_participant_token
    from config import LIVEKIT_WS_URL, USER_PROFILES

    username = current_user()
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            abort(404, description="sesión no encontrada")

        is_assigned = db.execute(
            "SELECT 1 FROM podcast_directors WHERE username=? AND shared_project_id=?",
            (username, sess["shared_project_id"]),
        ).fetchone()
        existing = db.execute(
            "SELECT * FROM participants WHERE session_id=? AND username=? AND role='director'",
            (sid, username),
        ).fetchone()

        if not is_assigned and not existing:
            return jsonify({"error": "no tienes permiso de director para este podcast"}), 403

        active_director = db.execute(
            "SELECT id, username FROM participants WHERE session_id=? AND role='director' AND status IN ('connected','active')",
            (sid,),
        ).fetchone()
        if active_director and active_director["username"] != username:
            return jsonify({"error": "ya hay un director conectado a esta sesión"}), 409

        if not existing:
            profile = USER_PROFILES.get(username, {})
            db.execute(
                "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
                "VALUES (?, ?, ?, ?, 'director', 'connected')",
                (sid, username, profile.get("display_name", username), secrets.token_urlsafe(32)),
            )
        else:
            db.execute(
                "UPDATE participants SET status='connected', joined_at=datetime('now') WHERE id=?",
                (existing["id"],),
            )
        db.commit()

        p = db.execute(
            "SELECT * FROM participants WHERE session_id=? AND username=? AND role='director'",
            (sid, username),
        ).fetchone()

        token_jwt = generate_participant_token(
            room_name=sess["livekit_room_name"],
            identity=f"director_{p['id']}",
            display_name=p["display_name"],
            is_director=True,
        )
        return jsonify({
            "participant_id": p["id"],
            "display_name": p["display_name"],
            "role": "director",
            "livekit_ws_url": LIVEKIT_WS_URL,
            "livekit_token": token_jwt,
            "room_name": sess["livekit_room_name"],
            "session": {
                "id": sess["id"],
                "title": sess["title"],
                "status": sess["status"],
                "started_at": sess["started_at"],
            },
        })
    finally:
        db.close()


# ---------------------------------------------------------------------------
# My director podcasts
# ---------------------------------------------------------------------------

@bp.get("/api/director/my-podcasts")
@require_auth
def my_director_podcasts():
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM podcast_directors WHERE username=?",
            (current_user(),),
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Overlay injection
# ---------------------------------------------------------------------------

@bp.post("/api/sessions/<int:sid>/director/inject")
@require_auth
def inject_overlay(sid):
    db = get_db()
    try:
        username = _require_director(db, sid)
        data = request.get_json(silent=True) or {}
        event_type = data.get("event_type", "")
        if event_type not in ("banner", "sponsor", "comment", "segment", "countdown", "graphic"):
            return jsonify({"error": f"event_type inválido: {event_type}"}), 400

        payload = json.dumps(data.get("payload", {}), ensure_ascii=False)
        file_path = data.get("file_path")
        duration = data.get("duration_seconds")

        sess = db.execute("SELECT started_at FROM sessions WHERE id=?", (sid,)).fetchone()
        offset = None
        if sess and sess["started_at"]:
            from datetime import datetime, timezone
            started = datetime.fromisoformat(sess["started_at"])
            offset = (datetime.now(timezone.utc).replace(tzinfo=None) - started).total_seconds()

        cur = db.execute(
            "INSERT INTO director_events (session_id, event_type, payload, file_path, recording_offset_seconds, duration_seconds, created_by) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (sid, event_type, payload, file_path, offset, duration, username),
        )
        db.commit()
        return jsonify({"event_id": cur.lastrowid, "recording_offset_seconds": offset}), 201
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/director/events/<int:eid>/remove")
@require_auth
def remove_overlay(sid, eid):
    db = get_db()
    try:
        _require_director(db, sid)
        db.execute(
            "UPDATE director_events SET removed_at=datetime('now') WHERE id=? AND session_id=?",
            (eid, sid),
        )
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>/director/events")
@require_auth
def list_director_events(sid):
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM director_events WHERE session_id=? ORDER BY injected_at",
            (sid,),
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Asset upload (graphics/images)
# ---------------------------------------------------------------------------

@bp.post("/api/sessions/<int:sid>/director/assets")
@require_auth
def upload_asset(sid):
    db = get_db()
    try:
        _require_director(db, sid)
    finally:
        db.close()

    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido"}), 400

    allowed = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"}
    ext = Path(f.filename).suffix.lower()
    if ext not in allowed:
        return jsonify({"error": f"extensión no soportada: {ext}"}), 400

    dest_dir = session_dir(sid) / "director_assets"
    dest_dir.mkdir(parents=True, exist_ok=True)

    import uuid
    safe_name = f"asset_{uuid.uuid4().hex[:8]}{ext}"
    dest = dest_dir / safe_name
    f.save(str(dest))

    return jsonify({
        "file_path": f"director_assets/{safe_name}",
        "filename": safe_name,
        "size_bytes": dest.stat().st_size,
    }), 201


@bp.get("/api/sessions/<int:sid>/director/assets")
@require_auth
def list_assets(sid):
    assets_dir = session_dir(sid) / "director_assets"
    if not assets_dir.exists():
        return jsonify([])
    files = []
    for f in sorted(assets_dir.iterdir()):
        if f.is_file():
            files.append({
                "filename": f.name,
                "file_path": f"director_assets/{f.name}",
                "size_bytes": f.stat().st_size,
                "url": f"/api/sessions/{sid}/director/assets/{f.name}",
            })
    return jsonify(files)


@bp.get("/api/sessions/<int:sid>/director/branding")
@require_auth
def director_branding(sid):
    """Branding del podcast + sponsors del episodio, para armar cintillos.
    Sesiones viejas sin sponsors_json caen a los sponsors de los bloques
    (chapter markers) que prePod ya importó."""
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        keys = sess.keys()
        name = (sess["podcast_name"] if "podcast_name" in keys else None) \
            or (sess["title"] or "").split("·")[0].strip() or "Podcast"
        logo = sess["podcast_logo_url"] if "podcast_logo_url" in keys else None
        sponsors = []
        raw = sess["sponsors_json"] if "sponsors_json" in keys else None
        if raw:
            try:
                sponsors = json.loads(raw)
            except (TypeError, ValueError):
                sponsors = []
        if not sponsors:
            rows = db.execute(
                "SELECT DISTINCT sponsor_name, sponsor_copy, sponsor_logo_url "
                "FROM chapter_markers WHERE session_id=? AND sponsor_name IS NOT NULL",
                (sid,),
            ).fetchall()
            sponsors = [{"name": r["sponsor_name"], "copy": r["sponsor_copy"],
                         "logo_url": r["sponsor_logo_url"]} for r in rows]
        return jsonify({"podcast_name": name, "podcast_logo_url": logo,
                        "sponsors": sponsors})
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/director/assets/from-url")
@require_auth
def upload_asset_from_url(sid):
    """Descarga una imagen (p. ej. el logo alojado en prePod) y la guarda
    como asset del director — evita el CORS de re-subirla desde el navegador."""
    db = get_db()
    try:
        _require_director(db, sid)
    finally:
        db.close()
    data = request.get_json(silent=True) or {}
    url = (data.get("url") or "").strip()
    if not url.startswith(("http://", "https://")):
        return jsonify({"error": "url inválida"}), 400
    import requests as _rq
    try:
        resp = _rq.get(url, timeout=15, stream=True)
        resp.raise_for_status()
    except _rq.RequestException as e:
        return jsonify({"error": f"no se pudo descargar: {e}"}), 502
    ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip().lower()
    ext_by_type = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif",
                   "image/webp": ".webp", "image/svg+xml": ".svg"}
    ext = ext_by_type.get(ctype) or Path(url.split("?")[0]).suffix.lower()
    if ext not in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"):
        return jsonify({"error": f"tipo no soportado: {ctype or ext}"}), 400
    import uuid
    dest_dir = session_dir(sid) / "director_assets"
    dest_dir.mkdir(parents=True, exist_ok=True)
    safe_name = f"asset_{uuid.uuid4().hex[:8]}{ext}"
    dest = dest_dir / safe_name
    size = 0
    with open(dest, "wb") as out:
        for chunk in resp.iter_content(65536):
            size += len(chunk)
            if size > 5 * 1024 * 1024:
                out.close()
                dest.unlink(missing_ok=True)
                return jsonify({"error": "imagen demasiado grande (máx 5 MB)"}), 413
            out.write(chunk)
    return jsonify({"file_path": f"director_assets/{safe_name}",
                    "filename": safe_name, "size_bytes": size}), 201


@bp.get("/api/sessions/<int:sid>/director/assets/<path:filename>")
def serve_asset(sid, filename):
    # Con sesión iniciada (host/director) o con el invite token de un
    # participante de ESTA sesión — los invitados también ven los logos.
    if not current_user():
        token = request.args.get("token") or ""
        db = get_db()
        try:
            ok = token and db.execute(
                "SELECT 1 FROM participants WHERE session_id=? AND invite_token=?",
                (sid, token),
            ).fetchone()
        finally:
            db.close()
        if not ok:
            return jsonify({"error": "no autenticado"}), 401
    import os
    from flask import send_from_directory
    base = (session_dir(sid) / "director_assets").resolve()
    target = (base / filename).resolve()
    if not str(target).startswith(str(base) + os.sep):
        abort(403)
    if not target.is_file():
        abort(404)
    return send_from_directory(str(base), filename)


# ---------------------------------------------------------------------------
# Force-mute
# ---------------------------------------------------------------------------

def _require_director_or_host(db, sid):
    """Director, host o co-host de la sesión (los invitados no)."""
    username = current_user()
    if _is_director(db, sid, username):
        return username
    sess = db.execute("SELECT created_by FROM sessions WHERE id=?", (sid,)).fetchone()
    if sess and sess["created_by"] == username:
        return username
    row = db.execute(
        "SELECT 1 FROM participants WHERE session_id=? AND username=? "
        "AND role IN ('host', 'co-host')",
        (sid, username),
    ).fetchone()
    if row:
        return username
    abort(403, description="solo el director o un conductor puede realizar esta acción")


@bp.post("/api/sessions/<int:sid>/participants/<int:pid>/force-mute")
@require_auth
def force_mute(sid, pid):
    db = get_db()
    try:
        username = _require_director_or_host(db, sid)
        p = db.execute(
            "SELECT id, display_name FROM participants WHERE id=? AND session_id=?",
            (pid, sid),
        ).fetchone()
        if not p:
            return jsonify({"error": "participante no encontrado"}), 404

        sess = db.execute("SELECT started_at FROM sessions WHERE id=?", (sid,)).fetchone()
        offset = None
        if sess and sess["started_at"]:
            from datetime import datetime, timezone
            started = datetime.fromisoformat(sess["started_at"])
            offset = (datetime.now(timezone.utc).replace(tzinfo=None) - started).total_seconds()

        db.execute(
            "INSERT INTO director_events (session_id, event_type, payload, recording_offset_seconds, created_by) "
            "VALUES (?, 'action', ?, ?, ?)",
            (sid, json.dumps({"action": "force_mute", "target_participant_id": pid, "target_name": p["display_name"]}), offset, username),
        )
        db.commit()
        return jsonify({"ok": True, "target": pid})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Director cue (persisted)
# ---------------------------------------------------------------------------

@bp.post("/api/sessions/<int:sid>/director/cue")
@require_auth
def send_cue(sid):
    db = get_db()
    try:
        username = _require_director(db, sid)
        data = request.get_json(silent=True) or {}
        cue = data.get("cue", "CUSTOM")
        text = data.get("text", "")
        target = data.get("target", "all")

        sess = db.execute("SELECT started_at FROM sessions WHERE id=?", (sid,)).fetchone()
        offset = None
        if sess and sess["started_at"]:
            from datetime import datetime, timezone
            started = datetime.fromisoformat(sess["started_at"])
            offset = (datetime.now(timezone.utc).replace(tzinfo=None) - started).total_seconds()

        cur = db.execute(
            "INSERT INTO director_events (session_id, event_type, payload, recording_offset_seconds, created_by) "
            "VALUES (?, 'cue', ?, ?, ?)",
            (sid, json.dumps({"cue": cue, "text": text, "target": target}), offset, username),
        )
        db.commit()
        return jsonify({"event_id": cur.lastrowid}), 201
    finally:
        db.close()
