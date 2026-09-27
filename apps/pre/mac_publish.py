"""
API para postPod de Mac: subida por partes de archivos grandes (100 MB–GB)
y publicación de episodios reutilizando la configuración existente de prePod
(hosting VPS + feed RSS y YouTube OAuth por podcast).

Endpoints (todos requieren la sesión de /api/auth/login):
    POST /api/mac/uploads                              {filename, size} → {upload_id}
    PUT  /api/mac/uploads/<upload_id>/chunk?index=N    cuerpo binario ≤ 16 MB, secuencial
    POST /api/mac/uploads/<upload_id>/finish           → verifica tamaño → {ok}
    POST /api/mac/publish/audio                        {slug, episode_id, upload_id} → {job_id}
    POST /api/mac/publish/youtube                      {slug, episode_id, upload_id, title, ...} → {job_id}
    GET  /api/mac/jobs/<job_id>                        → {status, progress, result, error}
    GET  /api/mac/podcasts/<slug>/publish-status?episode_id=N

Los uploads viven en podcasts/_uploads/ y se limpian a las 24 h.
Los jobs corren en hilos daemon dentro del único worker de gunicorn;
se pierden si el servicio se reinicia (el cliente debe reintentar).
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from pathlib import Path

from flask import Blueprint, jsonify, request, session

from auth import require_auth
from config import PODCASTS_DIR, policy_for
from db import get_db

bp = Blueprint("mac_publish", __name__, url_prefix="/api/mac")

CHUNK_MAX = 16 * 1024 * 1024   # 16 MB por chunk
UPLOAD_MAX = 20 * 1024 ** 3    # 20 GB: tope de tamaño declarado por upload
UPLOAD_TTL = 24 * 3600         # limpiar uploads abandonados a las 24 h


# ---------------------------------------------------------------------------
# Upload store (filesystem: podcasts/_uploads/<upload_id>.part + .json)
# ---------------------------------------------------------------------------

def _uploads_dir() -> Path:
    d = PODCASTS_DIR / "_uploads"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _meta_path(upload_id: str) -> Path:
    return _uploads_dir() / f"{upload_id}.json"


def _read_meta(upload_id: str) -> dict | None:
    p = _meta_path(upload_id)
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return None


def _write_meta(upload_id: str, meta: dict):
    p = _meta_path(upload_id)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(meta))
    os.replace(tmp, p)


def _cleanup_stale_uploads():
    cutoff = time.time() - UPLOAD_TTL
    for f in _uploads_dir().iterdir():
        try:
            if f.stat().st_mtime < cutoff:
                f.unlink()
        except OSError:
            pass


def _delete_upload(upload_id: str):
    meta = _read_meta(upload_id) or {}
    for name in (f"{upload_id}.part", meta.get("stored_name"), f"{upload_id}.json"):
        if not name:
            continue
        try:
            (_uploads_dir() / name).unlink(missing_ok=True)
        except OSError:
            pass
    with _upload_locks_guard:
        _upload_locks.pop(upload_id, None)


def _release_upload_claim(upload_id: str):
    """Release a previously set claim so the client can retry without re-uploading."""
    with _upload_lock(upload_id):
        meta = _read_meta(upload_id)
        if meta and meta.pop("claimed", None):
            _write_meta(upload_id, meta)


def _resolve_upload(upload_id: str) -> tuple[Path | None, dict | None]:
    """Return (path, meta) for a finished upload, or (None, None)."""
    meta = _read_meta(upload_id)
    if not meta or not meta.get("complete") or not meta.get("stored_name"):
        return None, None
    path = _uploads_dir() / meta["stored_name"]
    if not path.is_file():
        return None, None
    return path, meta


# ---------------------------------------------------------------------------
# Acceso por podcast (mismo criterio que el guard de app.py, que no cubre /api/mac)
# ---------------------------------------------------------------------------

def _podcast_access_error(slug: str):
    """Return a (response, status) tuple if access must be denied, else None."""
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    username = session.get("username")
    if policy_for(username).get("see_all"):
        return None
    try:
        db = get_db(slug)
        try:
            row = db.execute(
                "SELECT owner_username, extra_hosts FROM podcast_meta WHERE slug=?",
                (slug,),
            ).fetchone()
        finally:
            db.close()
    except Exception:
        return None
    if not row:
        return None
    owner = row["owner_username"] or "admin"
    extras = []
    if row["extra_hosts"]:
        try:
            v = json.loads(row["extra_hosts"])
            if isinstance(v, list):
                extras = [str(x) for x in v]
        except (TypeError, ValueError):
            pass
    if username != owner and username not in extras:
        return jsonify({"error": "no autorizado para este podcast"}), 403
    return None


# ---------------------------------------------------------------------------
# Registro de jobs en memoria (gunicorn corre con 1 worker → seguro)
# ---------------------------------------------------------------------------

_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()


def _create_job() -> str:
    job_id = uuid.uuid4().hex
    with _jobs_lock:
        _jobs[job_id] = {"status": "queued", "progress": 0.0, "result": None, "error": None}
    return job_id


def _update_job(job_id: str, **fields):
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job:
            job.update(fields)


@bp.get("/jobs/<job_id>")
@require_auth
def get_job(job_id):
    with _jobs_lock:
        job = _jobs.get(job_id)
        if not job:
            return jsonify({"error": "job no encontrado"}), 404
        return jsonify(dict(job))


_upload_locks: dict[str, threading.Lock] = {}
_upload_locks_guard = threading.Lock()


def _upload_lock(upload_id: str) -> threading.Lock:
    with _upload_locks_guard:
        return _upload_locks.setdefault(upload_id, threading.Lock())


# ---------------------------------------------------------------------------
# Endpoints de subida por partes
# ---------------------------------------------------------------------------

@bp.post("/uploads")
@require_auth
def create_upload():
    _cleanup_stale_uploads()
    data = request.get_json(silent=True) or {}
    filename = (data.get("filename") or "").strip()
    size = data.get("size")
    if not filename or not isinstance(size, int) or size <= 0:
        return jsonify({"error": "filename y size (bytes, > 0) son requeridos"}), 400
    filename = Path(filename).name
    if not filename or len(filename) > 255:
        return jsonify({"error": "filename inválido"}), 400
    if size > UPLOAD_MAX:
        return jsonify({"error": "size supera el máximo de 20 GB"}), 413

    upload_id = uuid.uuid4().hex
    (_uploads_dir() / f"{upload_id}.part").touch()
    _write_meta(upload_id, {
        "filename": filename,
        "size": size,
        "next_index": 0,
        "complete": False,
        "created_at": time.time(),
    })
    return jsonify({"upload_id": upload_id})


@bp.put("/uploads/<upload_id>/chunk")
@require_auth
def upload_chunk(upload_id):
    with _upload_lock(upload_id):
        meta = _read_meta(upload_id)
        if not meta:
            return jsonify({"error": "upload no encontrado"}), 404
        if meta.get("complete"):
            return jsonify({"error": "upload ya finalizado"}), 409

        index = request.args.get("index", type=int)
        if index is None:
            return jsonify({"error": "parámetro index requerido"}), 400
        if index != meta["next_index"]:
            return jsonify({
                "error": f"chunk fuera de orden: se esperaba index={meta['next_index']}",
                "next_index": meta["next_index"],
            }), 409

        body = request.get_data(cache=False)
        if not body:
            return jsonify({"error": "cuerpo binario vacío"}), 400
        if len(body) > CHUNK_MAX:
            return jsonify({"error": "el chunk supera el máximo de 16 MB"}), 413

        part = _uploads_dir() / f"{upload_id}.part"
        if not part.is_file():
            return jsonify({"error": "upload no encontrado"}), 404
        with part.open("ab") as fh:
            fh.write(body)

        meta["next_index"] = index + 1
        _write_meta(upload_id, meta)
        return jsonify({"ok": True, "received": part.stat().st_size})


@bp.post("/uploads/<upload_id>/finish")
@require_auth
def finish_upload(upload_id):
    with _upload_lock(upload_id):
        meta = _read_meta(upload_id)
        if not meta:
            return jsonify({"error": "upload no encontrado"}), 404
        if meta.get("complete"):
            return jsonify({"ok": True, "size": meta["size"]})

        part = _uploads_dir() / f"{upload_id}.part"
        if not part.is_file():
            return jsonify({"error": "upload no encontrado"}), 404

        actual = part.stat().st_size
        if actual != meta["size"]:
            return jsonify({
                "error": f"tamaño incorrecto: se esperaban {meta['size']} bytes y llegaron {actual}",
            }), 400

        # Conservar la extensión original: el nombre final del audio y el mimetype
        # del video en YouTube dependen del sufijo del archivo.
        suffix = Path(meta["filename"]).suffix
        if not re.fullmatch(r"\.[A-Za-z0-9]{1,10}", suffix or ""):
            suffix = ".bin"
        stored = _uploads_dir() / f"{upload_id}{suffix}"
        part.rename(stored)
        meta["complete"] = True
        meta["stored_name"] = stored.name
        _write_meta(upload_id, meta)
        return jsonify({"ok": True, "size": actual})


# ---------------------------------------------------------------------------
# Publicación
# ---------------------------------------------------------------------------

def _parse_publish_payload():
    """Valida el cuerpo común {slug, episode_id, upload_id}.
    Returns (slug, episode_id, upload_path, meta, None) o (None, None, None, None, error_response)."""
    data = request.get_json(silent=True) or {}
    slug = (data.get("slug") or "").strip()
    episode_id = data.get("episode_id")
    upload_id = (data.get("upload_id") or "").strip()
    if not slug or not isinstance(episode_id, int) or not upload_id:
        return None, None, None, None, (jsonify(
            {"error": "slug, episode_id (int) y upload_id son requeridos"}), 400)

    denied = _podcast_access_error(slug)
    if denied:
        return None, None, None, None, denied

    with _upload_lock(upload_id):
        path, meta = _resolve_upload(upload_id)
        if not path:
            return None, None, None, None, (jsonify(
                {"error": "upload no encontrado o incompleto"}), 404)
        if meta.get("claimed"):
            return None, None, None, None, (jsonify(
                {"error": "el upload ya está siendo publicado"}), 409)
        meta["claimed"] = True
        _write_meta(upload_id, meta)

    return slug, episode_id, path, {"upload_id": upload_id, **meta}, None


@bp.post("/publish/audio")
@require_auth
def publish_audio():
    slug, episode_id, path, meta, error = _parse_publish_payload()
    if error:
        return error

    job_id = _create_job()

    def _run():
        _update_job(job_id, status="running", progress=0.1)
        try:
            from episodes import upload_episode_media
            result = upload_episode_media(slug, episode_id, path)
        except Exception as e:
            result = {"ok": False, "error": f"error inesperado: {str(e)[:300]}"}
        if result["ok"]:
            _update_job(job_id, status="done", progress=1.0,
                        result={"media_url": result["media_url"]})
            _delete_upload(meta["upload_id"])
        else:
            _update_job(job_id, status="error", error=result["error"])
            _release_upload_claim(meta["upload_id"])

    threading.Thread(target=_run, daemon=True, name=f"mac-audio-{job_id}").start()
    return jsonify({"job_id": job_id}), 202
