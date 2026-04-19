import json
import shutil
import uuid
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request
from slugify import slugify

from auth import require_auth
from config import DEFAULT_COLORS, PODCASTS_DIR
from db import get_db


bp = Blueprint("podcasts", __name__, url_prefix="/api/podcasts")


def _unique_slug(name: str) -> str:
    base = slugify(name) or "podcast"
    slug = base
    n = 2
    while (PODCASTS_DIR / slug).exists():
        slug = f"{base}-{n}"
        n += 1
    return slug


def _serialize_meta(row):
    return {
        "id": row["id"],
        "name": row["name"],
        "slug": row["slug"],
        "description": row["description"] or "",
        "tagline": row["tagline"] or "",
        "color_primary": row["color_primary"],
        "color_secondary": row["color_secondary"],
        "color_accent": row["color_accent"],
        "font_heading": row["font_heading"],
        "font_body": row["font_body"],
        "logo_filename": row["logo_filename"],
        "cover_filename": row["cover_filename"],
        "logo_url": (
            f"/media/podcasts/{row['slug']}/branding/{row['logo_filename']}"
            if row["logo_filename"] else None
        ),
        "cover_url": (
            f"/media/podcasts/{row['slug']}/branding/{row['cover_filename']}"
            if row["cover_filename"] else None
        ),
        "shared_project_id": row["shared_project_id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


@bp.get("")
@require_auth
def list_podcasts():
    PODCASTS_DIR.mkdir(parents=True, exist_ok=True)
    out = []
    for entry in sorted(PODCASTS_DIR.iterdir()):
        if not entry.is_dir():
            continue
        slug = entry.name
        try:
            db = get_db(slug)
            row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
            db.close()
        except Exception:
            continue
        if row:
            out.append(_serialize_meta(row))
    out.sort(key=lambda m: m.get("created_at", ""), reverse=True)
    return jsonify(out)


@bp.post("")
@require_auth
def create_podcast():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "nombre requerido"}), 400

    slug = _unique_slug(name)
    project_dir = PODCASTS_DIR / slug
    (project_dir / "branding").mkdir(parents=True, exist_ok=True)

    db = get_db(slug)
    try:
        shared_id = uuid.uuid4().hex
        db.execute("""
            INSERT INTO podcast_meta (
                name, slug, description, tagline,
                color_primary, color_secondary, color_accent,
                shared_project_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            name, slug,
            data.get("description") or "",
            data.get("tagline") or "",
            DEFAULT_COLORS["primary"],
            DEFAULT_COLORS["secondary"],
            DEFAULT_COLORS["accent"],
            shared_id,
        ))
        db.commit()
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        return jsonify(_serialize_meta(row)), 201
    finally:
        db.close()


@bp.get("/<slug>")
@require_auth
def get_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not row:
            return jsonify({"error": "podcast no encontrado"}), 404
        return jsonify(_serialize_meta(row))
    finally:
        db.close()


@bp.put("/<slug>")
@require_auth
def update_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    data = request.get_json(silent=True) or {}

    allowed = {
        "name", "description", "tagline",
        "color_primary", "color_secondary", "color_accent",
        "font_heading", "font_body",
    }
    updates = {k: v for k, v in data.items() if k in allowed}
    if not updates:
        return jsonify({"error": "nada para actualizar"}), 400

    db = get_db(slug)
    try:
        # Audit trail
        existing = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not existing:
            return jsonify({"error": "podcast no encontrado"}), 404

        username = request.cookies.get("_user") or None
        for k, v in updates.items():
            old = existing[k] if k in existing.keys() else None
            if old != v:
                db.execute(
                    "INSERT INTO branding_history (field_name, old_value, new_value, changed_by) "
                    "VALUES (?, ?, ?, ?)",
                    (k, str(old) if old is not None else None, str(v) if v is not None else None, username),
                )

        cols = ", ".join(f"{k}=?" for k in updates) + ", updated_at=datetime('now')"
        params = list(updates.values()) + [slug]
        db.execute(f"UPDATE podcast_meta SET {cols} WHERE slug=?", params)
        db.commit()

        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        return jsonify(_serialize_meta(row))
    finally:
        db.close()


@bp.delete("/<slug>")
@require_auth
def delete_podcast(slug):
    project_dir = PODCASTS_DIR / slug
    if not project_dir.exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    shutil.rmtree(project_dir)
    return jsonify({"ok": True})
