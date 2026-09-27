import json
import shutil
import sqlite3
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from config import PROJECTS_DIR, GLOBAL_DIR
from db import _migrate_in_place


def export_project(slug: str) -> Path:
    project_dir = PROJECTS_DIR / slug
    if not project_dir.exists():
        raise FileNotFoundError(f"proyecto no encontrado: {slug}")

    meta_path = project_dir / "proyecto.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}

    exports_dir = project_dir / "exports"
    exports_dir.mkdir(parents=True, exist_ok=True)
    zip_name = f"{slug}_bundle.zip"
    zip_path = exports_dir / zip_name

    file_count = 0
    total_size = 0

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        db_src = project_dir / "proyecto.sqlite"
        if db_src.exists():
            db_tmp = exports_dir / "_bundle_db_copy.sqlite"
            shutil.copy2(db_src, db_tmp)
            zf.write(db_tmp, "proyecto.sqlite")
            db_tmp.unlink()
            file_count += 1

        media_dir = project_dir / "media"
        if media_dir.exists():
            for f in media_dir.rglob("*"):
                if f.is_file():
                    arcname = f"media/{f.relative_to(media_dir)}"
                    zf.write(f, arcname)
                    total_size += f.stat().st_size
                    file_count += 1

        branding_dir = project_dir / "branding"
        if branding_dir.exists():
            for f in branding_dir.rglob("*"):
                if f.is_file():
                    arcname = f"branding/{f.relative_to(branding_dir)}"
                    zf.write(f, arcname)
                    total_size += f.stat().st_size
                    file_count += 1

        director_count = 0
        director_dir = project_dir / "director_assets"
        if director_dir.exists():
            for f in director_dir.rglob("*"):
                if f.is_file():
                    arcname = f"director_assets/{f.relative_to(director_dir)}"
                    zf.write(f, arcname)
                    total_size += f.stat().st_size
                    file_count += 1
                    director_count += 1

        global_audio_count = 0
        global_audio_dir = GLOBAL_DIR / "audio"
        if global_audio_dir.exists():
            for f in sorted(global_audio_dir.glob("*.mp3")):
                zf.write(f, f"global_audio/{f.name}")
                total_size += f.stat().st_size
                file_count += 1
                global_audio_count += 1

        # Audio referenced by audio_lane_clips whose file no longer lives in
        # the project (e.g. moved to the global library) — recover it into
        # media/ so the bundle is self-contained and import finds it.
        recovered_from_global = []
        if db_src.exists():
            try:
                conn = sqlite3.connect(f"file:{db_src}?mode=ro", uri=True)
                rows = conn.execute(
                    "SELECT DISTINCT mf.filename, mf.file_type "
                    "FROM audio_lane_clips al "
                    "JOIN media_files mf ON mf.id = al.media_file_id"
                ).fetchall()
                conn.close()
            except sqlite3.DatabaseError:
                rows = []
            for filename, file_type in rows:
                if (media_dir / file_type / filename).exists():
                    continue  # ya incluido en el walk de media/
                gsrc = GLOBAL_DIR / file_type / filename
                if gsrc.is_file():
                    arcname = f"media/{file_type}/{filename}"
                    zf.write(gsrc, arcname)
                    total_size += gsrc.stat().st_size
                    file_count += 1
                    recovered_from_global.append(arcname)

        if meta_path.exists():
            zf.write(meta_path, "proyecto.json")
            file_count += 1

        manifest = {
            "app": "postpod",
            "version": 2,
            "slug": slug,
            "name": meta.get("name", slug),
            "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "file_count": file_count,
            "total_size_bytes": total_size,
            "includes": ["proyecto.json", "proyecto.sqlite", "media",
                         "branding", "director_assets", "global_audio"],
            "director_assets_count": director_count,
            "global_audio_count": global_audio_count,
            "recovered_from_global": recovered_from_global,
        }
        zf.writestr("manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False))

    return zip_path


def validate_import_zip(zip_path: Path) -> dict:
    errors = []
    manifest = None
    with zipfile.ZipFile(zip_path, "r") as zf:
        names = zf.namelist()
        if "manifest.json" not in names:
            errors.append("falta manifest.json")
        else:
            try:
                manifest = json.loads(zf.read("manifest.json"))
                if manifest.get("app") != "postpod":
                    errors.append("archivo no es un proyecto postPod válido")
            except (json.JSONDecodeError, KeyError):
                errors.append("manifest.json corrupto")
        if "proyecto.sqlite" not in names:
            errors.append("falta proyecto.sqlite")
        else:
            import tempfile
            with tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False) as tmp:
                tmp.write(zf.read("proyecto.sqlite"))
                tmp_path = Path(tmp.name)
            try:
                conn = sqlite3.connect(str(tmp_path))
                conn.execute("SELECT COUNT(*) FROM sqlite_master")
                conn.close()
            except sqlite3.DatabaseError:
                errors.append("base de datos corrupta")
            finally:
                tmp_path.unlink(missing_ok=True)
    return {"valid": len(errors) == 0, "errors": errors, "manifest": manifest}


def import_project(zip_path: Path, slug: str, owner_username: str | None = None) -> dict:
    project_dir = PROJECTS_DIR / slug
    project_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path, "r") as zf:
        for member in zf.namelist():
            if member == "manifest.json":
                continue
            target = project_dir / member
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(member) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)

    db_path = project_dir / "proyecto.sqlite"
    if db_path.exists():
        conn = sqlite3.connect(str(db_path))
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("PRAGMA foreign_keys = ON")
        _migrate_in_place(conn)
        conn.commit()
        conn.close()

    for sub in ("video", "audio", "images"):
        (project_dir / "media" / sub).mkdir(parents=True, exist_ok=True)
    (project_dir / "exports").mkdir(parents=True, exist_ok=True)

    meta_path = project_dir / "proyecto.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())
    else:
        meta = {"name": slug, "slug": slug}
    meta["id"] = slug
    meta["slug"] = slug
    if owner_username:
        meta["owner_username"] = owner_username
    meta["imported_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False))

    missing = []
    if db_path.exists():
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT id, filename, file_type FROM media_files").fetchall()
        conn.close()
        for r in rows:
            fpath = project_dir / "media" / r["file_type"] / r["filename"]
            if not fpath.exists():
                missing.append(f"{r['file_type']}/{r['filename']}")

    return {"slug": slug, "meta": meta, "missing_files": missing}


def unique_import_slug(desired: str) -> str:
    base = desired
    slug = base
    n = 2
    while (PROJECTS_DIR / slug).exists():
        slug = f"{base}-imported" if n == 2 else f"{base}-imported-{n - 1}"
        n += 1
    return slug
