"""
Import/export podcast projects as ZIP bundles.

ZIP structure:
    manifest.json           — app identifier, version, metadata
    podcast.db              — project SQLite database
    branding/               — logos, covers, backgrounds, member photos
    sponsors/               — sponsor logo files
"""

import json
import shutil
import sqlite3
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from config import PODCASTS_DIR


def export_podcast(slug: str) -> Path:
    pod_dir = PODCASTS_DIR / slug
    if not pod_dir.exists():
        raise FileNotFoundError(f"podcast no encontrado: {slug}")

    db_src = pod_dir / "proyecto.sqlite"
    if not db_src.exists():
        raise FileNotFoundError(f"base de datos no encontrada para {slug}")

    exports_dir = pod_dir / "exports"
    exports_dir.mkdir(parents=True, exist_ok=True)
    zip_path = exports_dir / f"{slug}_bundle.zip"

    file_count = 0
    total_size = 0

    conn = sqlite3.connect(str(db_src))
    conn.row_factory = sqlite3.Row
    meta_row = conn.execute("SELECT name, slug FROM podcast_meta LIMIT 1").fetchone()
    podcast_name = meta_row["name"] if meta_row else slug
    conn.close()

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        db_tmp = exports_dir / "_bundle_db_copy.sqlite"
        shutil.copy2(db_src, db_tmp)
        zf.write(db_tmp, "podcast.db")
        db_tmp.unlink()
        file_count += 1

        for subdir in ("branding", "sponsors"):
            d = pod_dir / subdir
            if d.exists():
                for f in d.rglob("*"):
                    if f.is_file():
                        arcname = f"{subdir}/{f.relative_to(d)}"
                        zf.write(f, arcname)
                        total_size += f.stat().st_size
                        file_count += 1

        manifest = {
            "app": "prepod",
            "version": 1,
            "slug": slug,
            "name": podcast_name,
            "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "file_count": file_count,
            "total_size_bytes": total_size,
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
                if manifest.get("app") != "prepod":
                    errors.append("archivo no es un proyecto prePod válido")
            except (json.JSONDecodeError, KeyError):
                errors.append("manifest.json corrupto")
        if "podcast.db" not in names:
            errors.append("falta podcast.db")
        else:
            import tempfile
            with tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False) as tmp:
                tmp.write(zf.read("podcast.db"))
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


def import_podcast(zip_path: Path, slug: str, owner_username: str | None = None) -> dict:
    pod_dir = PODCASTS_DIR / slug
    pod_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path, "r") as zf:
        for member in zf.namelist():
            if member == "manifest.json":
                continue
            if member == "podcast.db":
                target = pod_dir / "proyecto.sqlite"
            else:
                target = pod_dir / member
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(member) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)

    db_path = pod_dir / "proyecto.sqlite"
    if db_path.exists():
        from db import get_db
        conn = get_db(slug)
        if owner_username:
            conn.execute(
                "UPDATE podcast_meta SET owner_username=? WHERE id=(SELECT MIN(id) FROM podcast_meta)",
                (owner_username,),
            )
        conn.execute("UPDATE podcast_meta SET slug=?", (slug,))
        conn.commit()
        conn.close()

    for subdir in ("branding", "sponsors"):
        (pod_dir / subdir).mkdir(parents=True, exist_ok=True)

    return {"slug": slug}


def unique_import_slug(desired: str) -> str:
    base = desired
    slug = base
    n = 2
    while (PODCASTS_DIR / slug).exists():
        slug = f"{base}-imported" if n == 2 else f"{base}-imported-{n - 1}"
        n += 1
    return slug
