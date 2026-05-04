"""
Per-podcast sound library (soundboard preset). Files are stored under
PODCASTS_DIR/<slug>/sounds/. The same files are sent to prodPod when an
episode is dispatched, so the studio's soundboard comes pre-loaded with
the show's signature sounds.
"""

import shutil
import uuid
from pathlib import Path

from flask import Blueprint, abort, jsonify, request, send_from_directory

from auth import require_auth
from config import (
    ALLOWED_AUDIO_EXTS,
    GLOBAL_SOUNDS_DIR,
    INTEGRATION_SECRET,
    PODCASTS_DIR,
    SOUND_MAX_BYTES,
)
from db import get_db


bp = Blueprint("sounds", __name__)


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _sounds_dir(slug: str) -> Path:
    d = PODCASTS_DIR / slug / "sounds"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _serialize_sound(slug, row):
    return {
        "id": row["id"],
        "name": row["name"],
        "filename": row["filename"],
        "shortcut_key": row["shortcut_key"] or "",
        "color": row["color"] or "",
        "duration_seconds": row["duration_seconds"],
        "file_size_bytes": row["file_size_bytes"],
        "position": row["position"],
        "url": f"/media/podcasts/{slug}/sounds/{row['filename']}",
        "created_at": row["created_at"],
    }


@bp.get("/api/podcasts/<slug>/sounds")
@require_auth
def list_sounds(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM podcast_sounds ORDER BY position, id"
        ).fetchall()
        return jsonify([_serialize_sound(slug, r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/sounds")
@require_auth
def upload_sound(slug):
    _ensure_podcast(slug)
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido en campo 'file'"}), 400
    ext = Path(f.filename).suffix.lower()
    if ext not in ALLOWED_AUDIO_EXTS:
        return jsonify({
            "error": f"extensión no soportada: {ext}",
            "allowed": sorted(ALLOWED_AUDIO_EXTS),
        }), 400

    blob = f.read()
    if len(blob) > SOUND_MAX_BYTES:
        return jsonify({"error": f"archivo excede {SOUND_MAX_BYTES // (1024*1024)} MB"}), 413

    name = (request.form.get("name") or Path(f.filename).stem).strip() or Path(f.filename).stem
    shortcut = (request.form.get("shortcut_key") or "").strip()[:1] or None
    color = (request.form.get("color") or "").strip() or None

    filename = f"{uuid.uuid4().hex[:10]}{ext}"
    dest = _sounds_dir(slug) / filename
    dest.write_bytes(blob)

    db = get_db(slug)
    try:
        max_pos = db.execute("SELECT COALESCE(MAX(position), -1) AS m FROM podcast_sounds").fetchone()["m"]
        cur = db.execute(
            "INSERT INTO podcast_sounds (name, filename, shortcut_key, color, file_size_bytes, position) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (name, filename, shortcut, color, len(blob), max_pos + 1),
        )
        db.commit()
        row = db.execute("SELECT * FROM podcast_sounds WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_sound(slug, row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/sounds/<int:sid>")
@require_auth
def update_sound(slug, sid):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM podcast_sounds WHERE id=?", (sid,)).fetchone()
        if not row:
            return jsonify({"error": "sonido no encontrado"}), 404
        updates, params = [], []
        if "name" in data:
            n = (data["name"] or "").strip()
            if not n:
                return jsonify({"error": "name no puede estar vacío"}), 400
            updates.append("name=?"); params.append(n)
        if "shortcut_key" in data:
            updates.append("shortcut_key=?"); params.append((data["shortcut_key"] or "").strip()[:1] or None)
        if "color" in data:
            updates.append("color=?"); params.append((data["color"] or "").strip() or None)
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(sid)
        db.execute(f"UPDATE podcast_sounds SET {', '.join(updates)} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM podcast_sounds WHERE id=?", (sid,)).fetchone()
        return jsonify(_serialize_sound(slug, row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/sounds/<int:sid>")
@require_auth
def delete_sound(slug, sid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT filename FROM podcast_sounds WHERE id=?", (sid,)).fetchone()
        if not row:
            return jsonify({"error": "sonido no encontrado"}), 404
        try: (_sounds_dir(slug) / row["filename"]).unlink(missing_ok=True)
        except OSError: pass
        db.execute("DELETE FROM podcast_sounds WHERE id=?", (sid,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Global sound library (browse / preview / import into a podcast)
# ---------------------------------------------------------------------------

def _humanize(stem: str) -> str:
    """golpe_metal_2 → 'Golpe metal 2'."""
    return stem.replace("_", " ").replace("-", " ").strip().capitalize()


def _list_library() -> list[dict]:
    if not GLOBAL_SOUNDS_DIR or not GLOBAL_SOUNDS_DIR.exists():
        return []
    out = []
    for p in sorted(GLOBAL_SOUNDS_DIR.iterdir()):
        if not p.is_file() or p.suffix.lower() not in ALLOWED_AUDIO_EXTS:
            continue
        out.append({
            "filename": p.name,
            "name": _humanize(p.stem),
            "size_bytes": p.stat().st_size,
            "url": f"/api/sound-library/{p.name}",
        })
    return out


@bp.get("/api/sound-library")
@require_auth
def list_library():
    return jsonify({"available": GLOBAL_SOUNDS_DIR is not None, "sounds": _list_library()})


@bp.get("/api/sound-library/<path:filename>")
@require_auth
def serve_library_file(filename):
    if not GLOBAL_SOUNDS_DIR or not GLOBAL_SOUNDS_DIR.exists():
        abort(404)
    base = GLOBAL_SOUNDS_DIR.resolve()
    target = (base / filename).resolve()
    if not str(target).startswith(str(base)) or not target.is_file():
        abort(404)
    return send_from_directory(str(base), filename)


@bp.post("/api/podcasts/<slug>/sounds/import")
@require_auth
def import_from_library(slug):
    _ensure_podcast(slug)
    if not GLOBAL_SOUNDS_DIR or not GLOBAL_SOUNDS_DIR.exists():
        return jsonify({"error": "biblioteca global no disponible"}), 503
    data = request.get_json(silent=True) or {}
    files = data.get("filenames") or []
    if not isinstance(files, list) or not files:
        return jsonify({"error": "filenames (lista) requerido"}), 400

    base = GLOBAL_SOUNDS_DIR.resolve()
    dest_dir = _sounds_dir(slug)
    db = get_db(slug)
    try:
        max_pos = db.execute("SELECT COALESCE(MAX(position), -1) AS m FROM podcast_sounds").fetchone()["m"]
        imported = []
        for f in files:
            src = (base / f).resolve()
            if not str(src).startswith(str(base)) or not src.is_file():
                continue
            ext = src.suffix.lower()
            if ext not in ALLOWED_AUDIO_EXTS:
                continue
            new_name = f"{uuid.uuid4().hex[:10]}{ext}"
            dest = dest_dir / new_name
            shutil.copyfile(src, dest)
            max_pos += 1
            cur = db.execute(
                "INSERT INTO podcast_sounds (name, filename, file_size_bytes, position) "
                "VALUES (?, ?, ?, ?)",
                (_humanize(src.stem), new_name, dest.stat().st_size, max_pos),
            )
            row = db.execute("SELECT * FROM podcast_sounds WHERE id=?", (cur.lastrowid,)).fetchone()
            imported.append(_serialize_sound(slug, row))
        db.commit()
        return jsonify({"imported": imported, "count": len(imported)}), 201
    finally:
        db.close()


# Serving the audio file. Browser uses cookie auth; prodPod (server-side)
# uses the X-PodPod-Secret header. Either works.
@bp.get("/media/podcasts/<slug>/sounds/<path:filename>")
def serve_sound(slug, filename):
    from flask import session
    is_user = bool(session.get("username"))
    secret_ok = request.headers.get("X-PodPod-Secret") == INTEGRATION_SECRET
    if not (is_user or secret_ok):
        abort(401)
    base = (PODCASTS_DIR / slug / "sounds").resolve()
    target = (base / filename).resolve()
    if not str(target).startswith(str(base)):
        abort(403)
    if not target.is_file():
        abort(404)
    return send_from_directory(base, filename)
