import json
import shutil
import uuid
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request
from slugify import slugify

from auth import current_user, require_auth
from config import DEFAULT_COLORS, PODCASTS_DIR, USER_POLICY, policy_for
from db import get_db


# Legacy podcasts (created before owner tracking) belong to "admin".
LEGACY_OWNER = "admin"


def _row_owner(row) -> str:
    return (row["owner_username"] if "owner_username" in row.keys() and row["owner_username"]
            else LEGACY_OWNER)


def _row_extra_hosts(row) -> list[str]:
    if "extra_hosts" not in row.keys() or not row["extra_hosts"]:
        return []
    try:
        v = json.loads(row["extra_hosts"])
        return [str(x) for x in v] if isinstance(v, list) else []
    except (TypeError, ValueError):
        return []


def _can_see(username: str, owner: str, extra_hosts=()) -> bool:
    if policy_for(username).get("see_all"):
        return True
    return username == owner or username in (extra_hosts or [])


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
    keys = row.keys()
    return {
        "id": row["id"],
        "name": row["name"],
        "slug": row["slug"],
        "description": row["description"] or "",
        "tagline": row["tagline"] or "",
        "color_primary": row["color_primary"],
        "color_secondary": row["color_secondary"],
        "color_accent": row["color_accent"],
        "color_bg":   row["color_bg"]   if "color_bg"   in keys else None,
        "color_text": row["color_text"] if "color_text" in keys else None,
        "color_text_align": row["color_text_align"] if "color_text_align" in keys else None,
        "rss_override_url": row["rss_override_url"] if "rss_override_url" in keys else None,
        "landing_blocks": row["landing_blocks"] if "landing_blocks" in keys else None,
        "font_heading": row["font_heading"],
        "font_body": row["font_body"],
        "logo_filename": row["logo_filename"],
        "cover_filename": row["cover_filename"],
        "background_filename": row["background_filename"] if "background_filename" in keys else None,
        "logo_url": (
            f"/media/podcasts/{row['slug']}/branding/{row['logo_filename']}"
            if row["logo_filename"] else None
        ),
        "cover_url": (
            f"/media/podcasts/{row['slug']}/branding/{row['cover_filename']}"
            if row["cover_filename"] else None
        ),
        "background_url": (
            f"/media/podcasts/{row['slug']}/branding/{row['background_filename']}"
            if "background_filename" in keys and row["background_filename"] else None
        ),
        "shared_project_id": row["shared_project_id"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


@bp.get("")
@require_auth
def list_podcasts():
    PODCASTS_DIR.mkdir(parents=True, exist_ok=True)
    user = current_user()
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
        if row and _can_see(user, _row_owner(row), _row_extra_hosts(row)):
            out.append(_serialize_meta(row))
    out.sort(key=lambda m: m.get("created_at", ""), reverse=True)
    return jsonify(out)


def _user_podcast_count(username: str) -> int:
    n = 0
    for entry in PODCASTS_DIR.iterdir():
        if not entry.is_dir():
            continue
        try:
            db = get_db(entry.name)
            row = db.execute("SELECT owner_username FROM podcast_meta WHERE slug=?", (entry.name,)).fetchone()
            db.close()
        except Exception:
            continue
        if row and (row["owner_username"] or LEGACY_OWNER) == username:
            n += 1
    return n


@bp.post("")
@require_auth
def create_podcast():
    user = current_user()
    policy = policy_for(user)
    max_p = policy.get("max_podcasts")
    if max_p is not None and _user_podcast_count(user) >= max_p:
        return jsonify({"error": f"alcanzaste el máximo de {max_p} podcast(s) permitido(s) para tu usuario"}), 403

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
                shared_project_id, owner_username
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            name, slug,
            data.get("description") or "",
            data.get("tagline") or "",
            DEFAULT_COLORS["primary"],
            DEFAULT_COLORS["secondary"],
            DEFAULT_COLORS["accent"],
            shared_id,
            user,
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
        if not _can_see(current_user(), _row_owner(row), _row_extra_hosts(row)):
            return jsonify({"error": "no autorizado"}), 403
        return jsonify(_serialize_meta(row))
    finally:
        db.close()


@bp.get("/<slug>/hosts")
@require_auth
def list_hosts(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not row:
            return jsonify({"error": "podcast no encontrado"}), 404
        if not _can_see(current_user(), _row_owner(row), _row_extra_hosts(row)):
            return jsonify({"error": "no autorizado"}), 403
        return jsonify({
            "owner": _row_owner(row),
            "extra_hosts": _row_extra_hosts(row),
        })
    finally:
        db.close()


@bp.put("/<slug>/hosts")
@require_auth
def set_hosts(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    data = request.get_json(silent=True) or {}
    new_hosts = data.get("extra_hosts")
    if not isinstance(new_hosts, list):
        return jsonify({"error": "extra_hosts debe ser una lista"}), 400
    # Validate usernames against the configured user list.
    from config import USERS
    cleaned = []
    seen = set()
    for h in new_hosts:
        s = (str(h) or "").strip().lower()
        if not s or s in seen:
            continue
        if s not in USERS:
            return jsonify({"error": f"usuario desconocido: {s}"}), 400
        seen.add(s)
        cleaned.append(s)

    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not row:
            return jsonify({"error": "podcast no encontrado"}), 404
        owner = _row_owner(row)
        if current_user() != owner and not policy_for(current_user()).get("see_all"):
            return jsonify({"error": "solo el owner del podcast puede editar los hosts"}), 403
        # The owner is implicit and cannot appear in extra_hosts.
        cleaned = [h for h in cleaned if h != owner]
        db.execute(
            "UPDATE podcast_meta SET extra_hosts=?, updated_at=datetime('now') WHERE slug=?",
            (json.dumps(cleaned), slug),
        )
        db.commit()
        return jsonify({"owner": owner, "extra_hosts": cleaned})
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
        "color_bg", "color_text", "color_text_align",
        "rss_override_url", "landing_blocks",
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
        if not _can_see(current_user(), _row_owner(existing), _row_extra_hosts(existing)):
            return jsonify({"error": "no autorizado"}), 403

        username = current_user()
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

        # Pre-download Google Fonts TTFs so they're cached for FFmpeg exports
        font_names = [v for k, v in updates.items() if k in ("font_heading", "font_body") and v]
        if font_names:
            from shared_fonts import ensure_fonts
            ensure_fonts(*font_names)

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
    # Only the owner (or an admin) can delete.
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
    finally:
        db.close()
    if row:
        owner = _row_owner(row)
        user = current_user()
        if user != owner and not policy_for(user).get("see_all"):
            return jsonify({"error": "solo el owner puede eliminar este podcast"}), 403
    shutil.rmtree(project_dir)
    return jsonify({"ok": True})
