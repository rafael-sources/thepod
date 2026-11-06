import uuid
from pathlib import Path

from flask import Blueprint, abort, jsonify, request
from PIL import Image

from auth import require_auth
from config import ALLOWED_IMAGE_EXTS, COVER_MAX_SIZE, LOGO_MAX_SIZE, PODCASTS_DIR
from db import get_db


bp = Blueprint("branding", __name__)


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _process_and_save_image(src_bytes: bytes, dest_path: Path, max_size: tuple[int, int], ext: str):
    """Resize image to fit within max_size preserving aspect, save as PNG/JPEG/WebP."""
    from io import BytesIO
    img = Image.open(BytesIO(src_bytes))
    img.load()

    if ext in (".jpg", ".jpeg"):
        if img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1] if img.mode in ("RGBA", "LA") else None)
            img = bg
        else:
            img = img.convert("RGB")

    img.thumbnail(max_size, Image.LANCZOS)

    if ext in (".jpg", ".jpeg"):
        img.save(dest_path, "JPEG", quality=88, optimize=True, progressive=True)
    elif ext == ".webp":
        img.save(dest_path, "WEBP", quality=88, method=6)
    else:  # .png
        img.save(dest_path, "PNG", optimize=True)


@bp.post("/api/podcasts/<slug>/landing-image")
@require_auth
def upload_landing_image(slug):
    """
    Image upload endpoint matching the Editor.js Image Tool contract:
    multipart 'image' field; returns {success: 1, file: {url}} on success.
    """
    _ensure_podcast(slug)
    f = request.files.get("image") or request.files.get("file")
    if not f or not f.filename:
        return jsonify({"success": 0, "error": "archivo requerido"}), 400
    ext = Path(f.filename).suffix.lower()
    if ext not in ALLOWED_IMAGE_EXTS:
        return jsonify({"success": 0, "error": f"extensión no soportada: {ext}"}), 400

    dest_dir = PODCASTS_DIR / slug / "branding"
    dest_dir.mkdir(parents=True, exist_ok=True)
    filename = f"block_{uuid.uuid4().hex[:10]}{ext}"
    dest_path = dest_dir / filename
    try:
        # Cap max-side at 1600px to keep payloads sane.
        _process_and_save_image(f.read(), dest_path, (1600, 1600), ext)
    except Exception as e:
        return jsonify({"success": 0, "error": f"no pude procesar la imagen: {e}"}), 400
    return jsonify({
        "success": 1,
        "file": {"url": f"/media/podcasts/{slug}/branding/{filename}"},
    })


@bp.post("/api/podcasts/<slug>/branding/logo")
@require_auth
def upload_logo(slug):
    return _upload_branding(slug, "logo", LOGO_MAX_SIZE)


@bp.post("/api/podcasts/<slug>/branding/cover")
@require_auth
def upload_cover(slug):
    return _upload_branding(slug, "cover", COVER_MAX_SIZE)


@bp.post("/api/podcasts/<slug>/branding/background")
@require_auth
def upload_background(slug):
    return _upload_branding(slug, "background", (3840, 2160))


def _upload_branding(slug: str, kind: str, max_size: tuple[int, int]):
    _ensure_podcast(slug)
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido en campo 'file'"}), 400

    ext = Path(f.filename).suffix.lower()
    if ext not in ALLOWED_IMAGE_EXTS:
        return jsonify({
            "error": f"extensión no soportada: {ext}",
            "allowed": sorted(ALLOWED_IMAGE_EXTS),
        }), 400

    dest_dir = PODCASTS_DIR / slug / "branding"
    dest_dir.mkdir(parents=True, exist_ok=True)

    filename = f"{kind}_{uuid.uuid4().hex[:8]}{ext}"
    dest_path = dest_dir / filename

    try:
        _process_and_save_image(f.read(), dest_path, max_size, ext)
    except Exception as e:
        return jsonify({"error": f"no se pudo procesar la imagen: {e}"}), 400

    db = get_db(slug)
    try:
        row = db.execute(
            f"SELECT {kind}_filename AS current FROM podcast_meta WHERE slug=?", (slug,)
        ).fetchone()
        if row and row["current"]:
            old = dest_dir / row["current"]
            if old.exists() and old != dest_path:
                try: old.unlink()
                except OSError: pass

        db.execute(
            f"UPDATE podcast_meta SET {kind}_filename=?, updated_at=datetime('now') WHERE slug=?",
            (filename, slug),
        )
        db.commit()
    finally:
        db.close()

    return jsonify({
        "filename": filename,
        "url": f"/media/podcasts/{slug}/branding/{filename}",
    })


@bp.delete("/api/podcasts/<slug>/branding/logo")
@require_auth
def delete_logo(slug):
    return _delete_branding(slug, "logo")


@bp.delete("/api/podcasts/<slug>/branding/cover")
@require_auth
def delete_cover(slug):
    return _delete_branding(slug, "cover")


@bp.delete("/api/podcasts/<slug>/branding/background")
@require_auth
def delete_background(slug):
    return _delete_branding(slug, "background")


def _delete_branding(slug: str, kind: str):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            f"SELECT {kind}_filename AS current FROM podcast_meta WHERE slug=?", (slug,)
        ).fetchone()
        if not row or not row["current"]:
            return jsonify({"ok": True})
        f = PODCASTS_DIR / slug / "branding" / row["current"]
        if f.exists():
            try: f.unlink()
            except OSError: pass
        db.execute(
            f"UPDATE podcast_meta SET {kind}_filename=NULL, updated_at=datetime('now') WHERE slug=?",
            (slug,),
        )
        db.commit()
    finally:
        db.close()
    return jsonify({"ok": True})
