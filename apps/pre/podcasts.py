import json
import shutil
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from shared_users import default_owner

from flask import Blueprint, jsonify, request, send_file
from slugify import slugify

from auth import current_user, require_auth
from config import DEFAULT_COLORS, PODCASTS_DIR, USER_POLICY, policy_for
from db import get_db


# Anything created before there were owners belongs to the first administrator (shared_users.default_owner).


def _row_owner(row) -> str:
    return (row["owner_username"] if "owner_username" in row.keys() and row["owner_username"]
            else default_owner())


def _row_extra_hosts(row) -> list[str]:
    if "extra_hosts" not in row.keys() or not row["extra_hosts"]:
        return []
    try:
        v = json.loads(row["extra_hosts"])
        return [str(x) for x in v] if isinstance(v, list) else []
    except (TypeError, ValueError):
        return []


def _row_invitations(row) -> dict:
    if "host_invitations" not in row.keys() or not row["host_invitations"]:
        return {}
    try:
        v = json.loads(row["host_invitations"])
        return v if isinstance(v, dict) else {}
    except (TypeError, ValueError):
        return {}


def _save_invitations(db, slug: str, invitations: dict):
    db.execute(
        "UPDATE podcast_meta SET host_invitations=?, updated_at=datetime('now') WHERE slug=?",
        (json.dumps(invitations), slug),
    )


def _row_directors(row) -> list[str]:
    if "directors" not in row.keys() or not row["directors"]:
        return []
    try:
        v = json.loads(row["directors"])
        return [str(x) for x in v] if isinstance(v, list) else []
    except (TypeError, ValueError):
        return []


def _sync_directors_to_prodpod(shared_project_id: str, directors: list[str], assigned_by: str):
    """Best-effort push of the directors list to prodPod."""
    from shared_config import load_shared_config
    cfg = load_shared_config()
    prodpod_url = (cfg.get("prodpod_url") or "").rstrip("/")
    if not prodpod_url:
        return
    from config import INTEGRATION_SECRET
    import urllib.request
    import urllib.error
    body = json.dumps({
        "shared_project_id": shared_project_id,
        "directors": directors,
        "assigned_by": assigned_by,
    }).encode()
    req = urllib.request.Request(
        f"{prodpod_url}/api/integrations/sync-directors",
        data=body,
        headers={"Content-Type": "application/json", "X-PodPod-Secret": INTEGRATION_SECRET},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5):
            pass
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        pass


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
        "voice_presets": row["voice_presets"] if "voice_presets" in keys else None,
        "title_presets": row["title_presets"] if "title_presets" in keys else None,
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
        "directors": _row_directors(row),
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
        if row and (row["owner_username"] or default_owner()) == username:
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
        user = current_user()
        if not _can_see(user, _row_owner(row), _row_extra_hosts(row)):
            return jsonify({"error": "no autorizado"}), 403

        invitations = _row_invitations(row)
        extra = _row_extra_hosts(row)

        # Auto-accept: if current user is in extra_hosts and still "pendiente"
        inv = invitations.get(user)
        if inv and inv.get("status") == "pendiente" and user in extra:
            invitations[user]["status"] = "aceptado"
            invitations[user]["accepted_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
            _save_invitations(db, slug, invitations)
            db.commit()

        return jsonify({
            "owner": _row_owner(row),
            "extra_hosts": extra,
            "invitations": invitations,
            "directors": _row_directors(row),
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
        # Clean up invitations for removed hosts
        invitations = _row_invitations(row)
        removed = set(_row_extra_hosts(row)) - set(cleaned)
        for r in removed:
            invitations.pop(r, None)
        _save_invitations(db, slug, invitations)
        db.commit()
        return jsonify({"owner": owner, "extra_hosts": cleaned, "invitations": invitations})
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
        "rss_override_url", "landing_blocks", "voice_presets", "title_presets",
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


# ---------------------------------------------------------------------------
# Directors
# ---------------------------------------------------------------------------


@bp.post("/<slug>/directors")
@require_auth
def add_director(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    data = request.get_json(silent=True) or {}
    target = (data.get("username") or "").strip().lower()
    if not target:
        return jsonify({"error": "username requerido"}), 400

    from config import USERS
    if target not in USERS:
        return jsonify({"error": f"usuario desconocido: {target}"}), 400

    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not row:
            return jsonify({"error": "podcast no encontrado"}), 404
        owner = _row_owner(row)
        if current_user() != owner and not policy_for(current_user()).get("see_all"):
            return jsonify({"error": "solo el owner o admin puede asignar directores"}), 403

        directors = _row_directors(row)
        if target in directors:
            return jsonify({"error": "ese usuario ya es director"}), 400
        directors.append(target)
        db.execute(
            "UPDATE podcast_meta SET directors=?, updated_at=datetime('now') WHERE slug=?",
            (json.dumps(directors), slug),
        )
        db.commit()

        spid = row["shared_project_id"]
        if spid:
            _sync_directors_to_prodpod(spid, directors, current_user())

        return jsonify({"directors": directors})
    finally:
        db.close()


@bp.delete("/<slug>/directors/<username>")
@require_auth
def remove_director(slug, username):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404

    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not row:
            return jsonify({"error": "podcast no encontrado"}), 404
        owner = _row_owner(row)
        if current_user() != owner and not policy_for(current_user()).get("see_all"):
            return jsonify({"error": "solo el owner o admin puede quitar directores"}), 403

        directors = _row_directors(row)
        if username not in directors:
            return jsonify({"error": "usuario no es director"}), 404
        directors = [d for d in directors if d != username]
        db.execute(
            "UPDATE podcast_meta SET directors=?, updated_at=datetime('now') WHERE slug=?",
            (json.dumps(directors), slug),
        )
        db.commit()

        spid = row["shared_project_id"]
        if spid:
            _sync_directors_to_prodpod(spid, directors, current_user())

        return jsonify({"directors": directors})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# User search (autocomplete for adding hosts)
# ---------------------------------------------------------------------------

@bp.get("/search-users")
@require_auth
def search_users():
    q = (request.args.get("q") or "").strip().lower()
    if len(q) < 1:
        return jsonify([])
    from shared_users import list_user_rows
    results = []
    for r in list_user_rows():
        un = r["username"].lower()
        dn = (r["display_name"] or "").lower()
        if q in un or q in dn:
            results.append({
                "username": r["username"],
                "display_name": r["display_name"],
                "avatar_color": r["avatar_color"],
                "email": r.get("email") or "",
            })
    return jsonify(results[:10])


# ---------------------------------------------------------------------------
# Host invitation (add host + send branded email)
# ---------------------------------------------------------------------------

@bp.post("/<slug>/invite-host")
@require_auth
def invite_host(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    data = request.get_json(silent=True) or {}
    target_username = (data.get("username") or "").strip().lower()
    if not target_username:
        return jsonify({"error": "username requerido"}), 400

    from config import USERS
    if target_username not in USERS:
        return jsonify({"error": f"usuario desconocido: {target_username}"}), 400

    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not row:
            return jsonify({"error": "podcast no encontrado"}), 404
        owner = _row_owner(row)
        if current_user() != owner and not policy_for(current_user()).get("see_all"):
            return jsonify({"error": "solo el owner puede invitar hosts"}), 403

        existing = _row_extra_hosts(row)
        if target_username == owner:
            return jsonify({"error": "ese usuario ya es el owner"}), 400
        if target_username in existing:
            return jsonify({"error": "ese usuario ya es host"}), 400

        existing.append(target_username)
        db.execute(
            "UPDATE podcast_meta SET extra_hosts=?, updated_at=datetime('now') WHERE slug=?",
            (json.dumps(existing), slug),
        )

        from shared_users import get_user
        target_user = get_user(target_username)
        inviter_user = get_user(current_user())
        inviter_display = (inviter_user or {}).get("display_name") or current_user()
        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")

        # Track invitation metadata
        invitations = _row_invitations(row)
        invitations[target_username] = {
            "status": "pendiente",
            "invited_by": current_user(),
            "invited_by_name": inviter_display,
            "invited_at": now_str,
            "email_sent": False,
        }

        email_result = {"ok": False, "reason": "no_email"}
        target_email = (target_user or {}).get("email")
        if target_email:
            from email_helper import send_host_invitation_email, _public_base_url
            base = _public_base_url()
            podcast_color = row["color_primary"] or "#5a8bff"
            podcast_logo = ""
            if row["logo_filename"]:
                podcast_logo = f"{base}/media/podcasts/{slug}/branding/{row['logo_filename']}"

            email_result = send_host_invitation_email(
                to_email=target_email,
                host_name=target_user["display_name"],
                inviter_name=inviter_display,
                podcast_name=row["name"],
                podcast_color=podcast_color,
                podcast_logo_url=podcast_logo,
                action_url=f"{base}/podcast/{slug}" if base else f"/podcast/{slug}",
            )
            if email_result.get("ok"):
                invitations[target_username]["email_sent"] = True

        _save_invitations(db, slug, invitations)
        db.commit()

        return jsonify({
            "ok": True,
            "owner": owner,
            "extra_hosts": existing,
            "invitations": invitations,
            "email": email_result,
        })
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Import / Export
# ---------------------------------------------------------------------------

@bp.get("/<slug>/export-bundle")
@require_auth
def export_bundle(slug):
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404
    from project_io import export_podcast
    try:
        zip_path = export_podcast(slug)
        return send_file(str(zip_path), as_attachment=True,
                         download_name=f"{slug}_bundle.zip")
    except FileNotFoundError as e:
        return jsonify({"error": str(e)}), 404


@bp.post("/import")
@require_auth
def import_podcast_endpoint():
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo ZIP requerido"}), 400
    if not f.filename.lower().endswith(".zip"):
        return jsonify({"error": "solo archivos .zip"}), 400

    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        f.save(tmp)
        tmp_path = Path(tmp.name)

    try:
        from project_io import validate_import_zip, import_podcast, unique_import_slug
        result = validate_import_zip(tmp_path)
        if not result["valid"]:
            return jsonify({"error": "ZIP inválido", "details": result["errors"]}), 400

        desired = result["manifest"].get("slug", "imported-podcast")
        slug = unique_import_slug(desired)
        imp = import_podcast(tmp_path, slug, owner_username=current_user())
        return jsonify({"slug": imp["slug"], "name": result["manifest"].get("name", slug)}), 201
    finally:
        tmp_path.unlink(missing_ok=True)
