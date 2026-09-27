import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

from flask import Blueprint, jsonify, request, send_file
from slugify import slugify

from auth import current_user, require_auth
from config import ALLOWED_EXTS, MEDIA_TYPES, PROJECTS_DIR, ext_to_type
from db import get_db


bp = Blueprint("projects", __name__, url_prefix="/api/projects")


def _project_meta_path(slug):
    return PROJECTS_DIR / slug / "proyecto.json"


def _unique_slug(name: str) -> str:
    base = slugify(name) or "proyecto"
    slug = base
    n = 2
    while (PROJECTS_DIR / slug).exists():
        slug = f"{base}-{n}"
        n += 1
    return slug


def find_project_by_shared_id(shared_project_id: str, source_episode_id=None):
    """Look up a project by its shared_project_id (linked from prePod/prodPod).
    When source_episode_id is given, also match on source.episode.id so that
    different episodes of the same podcast don't collide."""
    if not shared_project_id:
        return None
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    for entry in PROJECTS_DIR.iterdir():
        if not entry.is_dir():
            continue
        meta = _read_meta(entry.name)
        if not meta or meta.get("shared_project_id") != shared_project_id:
            continue
        if source_episode_id is not None:
            src = meta.get("source") or {}
            ep = src.get("episode") or {}
            if str(ep.get("id", "")) != str(source_episode_id):
                continue
        return meta
    return None


def _read_meta(slug):
    path = _project_meta_path(slug)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def _write_meta(slug, data):
    _project_meta_path(slug).write_text(json.dumps(data, indent=2, ensure_ascii=False))


LEGACY_OWNER = "admin"


def _can_see(meta) -> bool:
    user = current_user()
    if not user:
        return False
    from config import policy_for
    if policy_for(user).get("see_all"):
        return True
    owner = (meta or {}).get("owner_username") or LEGACY_OWNER
    extras = (meta or {}).get("extra_hosts") or []
    return user == owner or user in extras


@bp.get("")
@require_auth
def list_projects():
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    out = []
    for entry in sorted(PROJECTS_DIR.iterdir()):
        if not entry.is_dir():
            continue
        meta = _read_meta(entry.name)
        if not meta or not _can_see(meta):
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("created_at", ""), reverse=True)
    return jsonify(out)


def _create_project_internal(name: str, shared_project_id: str = None,
                             source_info: dict = None, owner_username: str = None):
    """Shared project creation used by the public API and internal integrations."""
    slug = _unique_slug(name)
    project_dir = PROJECTS_DIR / slug
    for t in MEDIA_TYPES:
        (project_dir / "media" / t).mkdir(parents=True, exist_ok=True)

    get_db(slug).close()

    meta = {
        "id": slug,
        "name": name,
        "slug": slug,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    if shared_project_id:
        meta["shared_project_id"] = shared_project_id
    if source_info:
        meta["source"] = source_info
    if owner_username:
        meta["owner_username"] = owner_username
    _write_meta(slug, meta)
    return meta


@bp.post("")
@require_auth
def create_project():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "nombre requerido"}), 400
    meta = _create_project_internal(name, owner_username=current_user())
    return jsonify(meta), 201


@bp.get("/<slug>")
@require_auth
def get_project(slug):
    meta = _read_meta(slug)
    if not meta:
        return jsonify({"error": "proyecto no encontrado"}), 404
    if not _can_see(meta):
        return jsonify({"error": "no autorizado"}), 403
    return jsonify(meta)


@bp.delete("/<slug>")
@require_auth
def delete_project(slug):
    project_dir = PROJECTS_DIR / slug
    if not project_dir.exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    meta = _read_meta(slug) or {}
    if not _can_see(meta):
        return jsonify({"error": "no autorizado"}), 403
    shutil.rmtree(project_dir)
    return jsonify({"ok": True})


@bp.get("/<slug>/export-bundle")
@require_auth
def export_bundle(slug):
    project_dir = PROJECTS_DIR / slug
    if not project_dir.exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    meta = _read_meta(slug) or {}
    if not _can_see(meta):
        return jsonify({"error": "no autorizado"}), 403
    from project_io import export_project
    try:
        zip_path = export_project(slug)
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return send_file(
        str(zip_path),
        as_attachment=True,
        download_name=f"{slug}_bundle.zip",
    )


@bp.post("/import")
@require_auth
def import_project_endpoint():
    if "file" not in request.files:
        return jsonify({"error": "archivo requerido"}), 400
    f = request.files["file"]
    if not f.filename:
        return jsonify({"error": "archivo requerido"}), 400

    ext = Path(f.filename).suffix.lower()

    if ext == ".zip":
        return _import_zip(f)

    file_type = ext_to_type(ext)
    if not file_type:
        return jsonify({
            "error": f"extensión no soportada: {ext}",
            "allowed": {k: sorted(v) for k, v in ALLOWED_EXTS.items()},
        }), 400
    return _import_media_file(f, ext, file_type)


def _import_zip(f):
    import tempfile
    from project_io import import_project, unique_import_slug, validate_import_zip

    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        f.save(tmp)
        tmp_path = Path(tmp.name)

    try:
        validation = validate_import_zip(tmp_path)
        if not validation["valid"]:
            return jsonify({"error": "; ".join(validation["errors"])}), 400

        manifest = validation["manifest"] or {}
        desired_slug = manifest.get("slug", "imported-project")
        mode = request.form.get("mode", "copy")

        if mode == "replace" and (PROJECTS_DIR / desired_slug).exists():
            slug = desired_slug
            shutil.rmtree(PROJECTS_DIR / slug)
        else:
            slug = unique_import_slug(desired_slug)

        result = import_project(tmp_path, slug, owner_username=current_user())
        if result["missing_files"]:
            return jsonify({
                "slug": slug,
                "warning": f"{len(result['missing_files'])} archivos referenciados no encontrados en el zip",
                "missing": result["missing_files"][:10],
            }), 201
        return jsonify({"slug": slug, "meta": result["meta"]}), 201
    finally:
        tmp_path.unlink(missing_ok=True)


def _import_media_file(f, ext, file_type):
    import uuid
    from files import _probe_duration, _generate_thumbnail, _generate_end_thumbnail, _generate_waveform

    original_name = f.filename
    project_name = Path(original_name).stem
    meta = _create_project_internal(project_name, owner_username=current_user())
    slug = meta["slug"]

    filename = f"{uuid.uuid4().hex}{ext}"
    dest_dir = PROJECTS_DIR / slug / "media" / file_type
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename
    f.save(str(dest))

    size_bytes = dest.stat().st_size
    duration = _probe_duration(dest) if file_type in ("video", "audio") else None

    if file_type == "video":
        _generate_thumbnail(dest, duration)
        _generate_end_thumbnail(dest, duration)
    if file_type in ("video", "audio"):
        _generate_waveform(dest, duration)

    db = get_db(slug)
    try:
        cur = db.execute(
            "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
            "VALUES (?, ?, ?, ?, ?)",
            (filename, original_name, file_type, duration, size_bytes),
        )
        media_file_id = cur.lastrowid
        if file_type in ("video", "audio"):
            db.execute(
                "INSERT INTO timeline_clips (position, media_file_id, label, start_offset, end_offset, track) "
                "VALUES (0, ?, ?, 0, ?, 1)",
                (media_file_id, original_name, duration),
            )
        db.commit()
    finally:
        db.close()

    return jsonify({"slug": slug, "meta": meta}), 201


# ---------------------------------------------------------------------------
# Participants (imported from prePod, editable in postPod)
# ---------------------------------------------------------------------------

def _serialize_participant(row):
    return {
        "id": row["id"],
        "name": row["name"],
        "role": row["role"],
        "track": row["track"],
        "social_instagram": row["social_instagram"] or "",
        "social_twitter": row["social_twitter"] or "",
        "social_youtube": row["social_youtube"] or "",
        "social_tiktok": row["social_tiktok"] or "",
        "photo_filename": row["photo_filename"],
    }


@bp.get("/<slug>/participants")
@require_auth
def list_participants(slug):
    if not (PROJECTS_DIR / slug).exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM project_participants ORDER BY id"
        ).fetchall()
        return jsonify([_serialize_participant(r) for r in rows])
    finally:
        db.close()


@bp.put("/<slug>/participants/<int:pid>")
@require_auth
def update_participant(slug, pid):
    if not (PROJECTS_DIR / slug).exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM project_participants WHERE id=?", (pid,)).fetchone()
        if not row:
            return jsonify({"error": "participante no encontrado"}), 404
        updates, params = [], []
        for f in ("name", "role", "social_instagram", "social_twitter",
                  "social_youtube", "social_tiktok"):
            if f in data:
                updates.append(f"{f}=?")
                params.append((data[f] or "").strip() or None)
        if "track" in data:
            t = data["track"]
            updates.append("track=?")
            params.append(int(t) if t is not None else None)
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(pid)
        db.execute(f"UPDATE project_participants SET {', '.join(updates)} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM project_participants WHERE id=?", (pid,)).fetchone()
        return jsonify(_serialize_participant(row))
    finally:
        db.close()


@bp.post("/<slug>/participants")
@require_auth
def create_participant(slug):
    if not (PROJECTS_DIR / slug).exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name requerido"}), 400
    db = get_db(slug)
    try:
        cur = db.execute(
            "INSERT INTO project_participants (name, role, track, "
            "social_instagram, social_twitter, social_youtube, social_tiktok) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                name,
                (data.get("role") or "guest").strip(),
                int(data["track"]) if data.get("track") is not None else None,
                (data.get("social_instagram") or "").strip() or None,
                (data.get("social_twitter") or "").strip() or None,
                (data.get("social_youtube") or "").strip() or None,
                (data.get("social_tiktok") or "").strip() or None,
            ),
        )
        db.commit()
        row = db.execute("SELECT * FROM project_participants WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_participant(row)), 201
    finally:
        db.close()


@bp.delete("/<slug>/participants/<int:pid>")
@require_auth
def delete_participant(slug, pid):
    if not (PROJECTS_DIR / slug).exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    db = get_db(slug)
    try:
        db.execute("DELETE FROM project_participants WHERE id=?", (pid,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Sponsors
# ---------------------------------------------------------------------------

@bp.get("/<slug>/sponsors")
@require_auth
def list_sponsors(slug):
    if not (PROJECTS_DIR / slug).exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM project_sponsors ORDER BY position, id"
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Segments (episode blocks / topics)
# ---------------------------------------------------------------------------

@bp.get("/<slug>/segments")
@require_auth
def list_segments(slug):
    if not (PROJECTS_DIR / slug).exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT ps.*, sp.name AS sponsor_name "
            "FROM project_segments ps "
            "LEFT JOIN project_sponsors sp ON sp.id = ps.sponsor_id "
            "ORDER BY ps.position, ps.id"
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()
