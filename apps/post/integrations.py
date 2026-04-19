"""
Incoming app-to-app integrations. These endpoints are NOT protected by user
sessions — they're for server-to-server calls from prePod / prodPod. They
require a shared secret (`INTEGRATION_SECRET`) in the `X-PodPod-Secret`
header.
"""

import uuid
from datetime import datetime, timezone
from pathlib import Path

from flask import Blueprint, jsonify, request

from config import ALLOWED_EXTS, INTEGRATION_SECRET, PROJECTS_DIR, ext_to_type
from db import get_db
from files import _generate_thumbnail, _generate_waveform, _probe_duration, _project_file_url
from projects import _create_project_internal, _read_meta, find_project_by_shared_id


bp = Blueprint("integrations", __name__)


def _require_shared_secret():
    got = request.headers.get("X-PodPod-Secret") or request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if got != INTEGRATION_SECRET:
        return jsonify({"error": "no autorizado"}), 401
    return None


def _summarize_project(meta):
    if not meta:
        return None
    return {
        "slug": meta.get("slug"),
        "name": meta.get("name"),
        "shared_project_id": meta.get("shared_project_id"),
        "created_at": meta.get("created_at"),
        "source": meta.get("source"),
    }


@bp.get("/api/integrations/status")
def integration_status():
    """Return info about a project linked by shared_project_id, or 404."""
    err = _require_shared_secret()
    if err:
        return err
    spid = request.args.get("shared_project_id")
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400
    meta = find_project_by_shared_id(spid)
    if not meta:
        return jsonify({"found": False}), 404
    return jsonify({"found": True, "project": _summarize_project(meta)})


@bp.post("/api/integrations/prepod/import")
def import_from_prepod():
    """
    Create a postPod project from a prePod episode payload. If a project with
    the same shared_project_id already exists, return its info (idempotent).
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

    existing = find_project_by_shared_id(spid)
    if existing:
        return jsonify({"project": _summarize_project(existing), "created": False}), 200

    podcast = data.get("podcast") or {}
    episode = data.get("episode") or {}

    podcast_name = (podcast.get("name") or "").strip() or "Podcast"
    ep_num = episode.get("number")
    ep_title = (episode.get("title") or "").strip()
    if ep_num and ep_title:
        project_name = f"{podcast_name} · Ep {ep_num}: {ep_title}"
    elif ep_title:
        project_name = f"{podcast_name} · {ep_title}"
    else:
        project_name = podcast_name

    # Minimal source snapshot: who/what/when. Full payload preserved for reference.
    source_info = {
        "app": "prepod",
        "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "podcast": {
            "name": podcast_name,
            "slug": podcast.get("slug"),
            "description": podcast.get("description"),
            "branding": podcast.get("branding"),
        },
        "episode": {
            "id": episode.get("id"),
            "number": ep_num,
            "title": ep_title,
            "description": episode.get("description"),
            "scheduled_date": episode.get("scheduled_date"),
            "duration_estimate": episode.get("duration_estimate"),
            "script": episode.get("script") or [],
            "ideas": episode.get("ideas") or [],
            "links": episode.get("links") or [],
        },
    }

    meta = _create_project_internal(
        name=project_name,
        shared_project_id=spid,
        source_info=source_info,
    )
    return jsonify({"project": _summarize_project(meta), "created": True}), 201


@bp.post("/api/integrations/prodpod/import-track")
def import_track_from_prodpod():
    """
    Receive one recording track uploaded server-to-server by prodPod. Creates
    the target postPod project if it doesn't exist yet, stores the file in the
    project's media folder, and generates thumbnail/peaks sidecars so the
    editor can use it immediately.

    multipart/form-data fields:
        file               (required) the media blob
        shared_project_id  (required) link to the prePod/prodPod episode
        original_name      (optional) human-readable original filename
        track_type         (optional) video | audio | soundboard
        duration_seconds   (optional) best-effort hint
        participant_name   (optional) who recorded it, for display
        project_name       (optional) used only when auto-creating a project
    """
    err = _require_shared_secret()
    if err:
        return err

    spid = (request.form.get("shared_project_id") or "").strip()
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400

    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido en 'file'"}), 400

    original_name = (request.form.get("original_name") or f.filename).strip()
    incoming_ext = Path(original_name).suffix.lower() or Path(f.filename).suffix.lower()
    file_type = ext_to_type(incoming_ext)
    if not file_type:
        return jsonify({
            "error": f"extensión no soportada: {incoming_ext}",
            "allowed": {k: sorted(v) for k, v in ALLOWED_EXTS.items()},
        }), 400

    # Find or create the project
    meta = find_project_by_shared_id(spid)
    if not meta:
        project_name = (request.form.get("project_name") or "").strip() or f"Episodio {spid[:8]}"
        meta = _create_project_internal(
            name=project_name,
            shared_project_id=spid,
            source_info={
                "app": "prodpod",
                "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "auto_created_by": "prodpod_track_import",
            },
        )
    slug = meta["slug"]

    # Save under the project's media folder
    filename = f"{uuid.uuid4().hex}{incoming_ext}"
    dest_dir = PROJECTS_DIR / slug / "media" / file_type
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename
    f.save(str(dest))

    size_bytes = dest.stat().st_size

    # Duration: prefer uploader's hint when ffprobe can't read webm properly
    probed = _probe_duration(dest) if file_type in ("video", "audio") else None
    try:
        hinted = float(request.form.get("duration_seconds") or 0) or None
    except ValueError:
        hinted = None
    duration = probed or hinted

    thumbnail_url = None
    if file_type == "video":
        if _generate_thumbnail(dest, duration):
            from files import _project_thumb_url
            thumbnail_url = _project_thumb_url(slug, file_type, filename)

    peaks_url = None
    if file_type in ("video", "audio"):
        if _generate_waveform(dest, duration):
            from files import _project_peaks_url
            peaks_url = _project_peaks_url(slug, file_type, filename)

    # Register in the project's media db
    db = get_db(slug)
    try:
        cur = db.execute(
            "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
            "VALUES (?, ?, ?, ?, ?)",
            (filename, original_name, file_type, duration, size_bytes),
        )
        db.commit()
        file_id = cur.lastrowid
    finally:
        db.close()

    return jsonify({
        "project": _summarize_project(meta),
        "file": {
            "id": file_id,
            "filename": filename,
            "original_name": original_name,
            "file_type": file_type,
            "duration": duration,
            "size_bytes": size_bytes,
            "url": _project_file_url(slug, file_type, filename),
            "thumbnail_url": thumbnail_url,
            "peaks_url": peaks_url,
        },
    }), 201
