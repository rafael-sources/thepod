import json
import shutil
from datetime import datetime, timezone

from flask import Blueprint, jsonify, request
from slugify import slugify

from auth import require_auth
from config import MEDIA_TYPES, PROJECTS_DIR
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


def find_project_by_shared_id(shared_project_id: str):
    """Look up a project by its shared_project_id (linked from prePod/prodPod)."""
    if not shared_project_id:
        return None
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    for entry in PROJECTS_DIR.iterdir():
        if not entry.is_dir():
            continue
        meta = _read_meta(entry.name)
        if meta and meta.get("shared_project_id") == shared_project_id:
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


@bp.get("")
@require_auth
def list_projects():
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    out = []
    for entry in sorted(PROJECTS_DIR.iterdir()):
        if not entry.is_dir():
            continue
        meta = _read_meta(entry.name)
        if not meta:
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("created_at", ""), reverse=True)
    return jsonify(out)


def _create_project_internal(name: str, shared_project_id: str = None, source_info: dict = None):
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
    _write_meta(slug, meta)
    return meta


@bp.post("")
@require_auth
def create_project():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "nombre requerido"}), 400
    meta = _create_project_internal(name)
    return jsonify(meta), 201


@bp.get("/<slug>")
@require_auth
def get_project(slug):
    meta = _read_meta(slug)
    if not meta:
        return jsonify({"error": "proyecto no encontrado"}), 404
    return jsonify(meta)


@bp.delete("/<slug>")
@require_auth
def delete_project(slug):
    project_dir = PROJECTS_DIR / slug
    if not project_dir.exists():
        return jsonify({"error": "proyecto no encontrado"}), 404
    shutil.rmtree(project_dir)
    return jsonify({"ok": True})
