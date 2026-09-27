import json
import os
import shutil
import sqlite3
import threading
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from config import PROJECTS_DIR, GLOBAL_DIR, ext_to_type
from db import _migrate_in_place


_BUNDLE_CHUNK = 8 * 1024 * 1024  # write zip members in 8 MB blocks
_JOB_STALE_SECS = 120            # a "building" status older than this is a dead worker


def bundle_zip_path(slug: str) -> Path:
    return PROJECTS_DIR / slug / "exports" / f"{slug}_bundle.zip"


def _bundle_status_path(slug: str) -> Path:
    return PROJECTS_DIR / slug / "exports" / "_bundle_status.json"


def _compress_type_for(path: Path) -> int:
    # Video and audio are already compressed: deflating them wastes minutes
    # for ~0% gain. Everything else (sqlite, json, text, images) deflates.
    if ext_to_type(path.suffix.lower()) in ("video", "audio"):
        return zipfile.ZIP_STORED
    return zipfile.ZIP_DEFLATED


def _collect_bundle_files(slug: str, db_tmp: Path | None):
    """Everything that goes into the zip, resolved up-front so the total
    size is known before the first byte is written."""
    project_dir = PROJECTS_DIR / slug
    media_dir = project_dir / "media"
    files = []  # (src, arcname, compress_type)
    stats = {"director_assets_count": 0, "global_audio_count": 0,
             "recovered_from_global": []}

    if db_tmp is not None:
        files.append((db_tmp, "proyecto.sqlite", zipfile.ZIP_DEFLATED))

    if media_dir.exists():
        for f in sorted(media_dir.rglob("*")):
            if f.is_file():
                files.append((f, f"media/{f.relative_to(media_dir)}", _compress_type_for(f)))

    for extra in ("branding", "sponsors", "sounds", "guests"):
        extra_dir = project_dir / extra
        if extra_dir.exists():
            for f in sorted(extra_dir.rglob("*")):
                if f.is_file():
                    files.append((f, f"{extra}/{f.relative_to(extra_dir)}", _compress_type_for(f)))

    director_dir = project_dir / "director_assets"
    if director_dir.exists():
        for f in sorted(director_dir.rglob("*")):
            if f.is_file():
                files.append((f, f"director_assets/{f.relative_to(director_dir)}", _compress_type_for(f)))
                stats["director_assets_count"] += 1

    global_audio_dir = GLOBAL_DIR / "audio"
    if global_audio_dir.exists():
        for f in sorted(global_audio_dir.glob("*.mp3")):
            files.append((f, f"global_audio/{f.name}", zipfile.ZIP_STORED))
            stats["global_audio_count"] += 1

    # Audio referenced by audio_lane_clips whose file no longer lives in
    # the project (e.g. moved to the global library) — recover it into
    # media/ so the bundle is self-contained and import finds it.
    db_src = project_dir / "proyecto.sqlite"
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
                files.append((gsrc, arcname, _compress_type_for(gsrc)))
                stats["recovered_from_global"].append(arcname)

    meta_path = project_dir / "proyecto.json"
    if meta_path.exists():
        files.append((meta_path, "proyecto.json", zipfile.ZIP_DEFLATED))

    return files, stats


def export_project(slug: str, progress=None) -> Path:
    """Build {slug}_bundle.zip. progress(bytes_done, total_bytes) is called
    while each file is written (every 8 MB), not just between files. The zip
    is written to a .tmp sibling and os.replace()d into place, so a download
    of the previous bundle never sees a half-written file."""
    project_dir = PROJECTS_DIR / slug
    if not project_dir.exists():
        raise FileNotFoundError(f"proyecto no encontrado: {slug}")

    meta_path = project_dir / "proyecto.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}

    exports_dir = project_dir / "exports"
    exports_dir.mkdir(parents=True, exist_ok=True)
    zip_path = bundle_zip_path(slug)
    tmp_path = exports_dir / f"{slug}_bundle.zip.tmp"

    db_src = project_dir / "proyecto.sqlite"
    db_tmp = None
    if db_src.exists():
        db_tmp = exports_dir / "_bundle_db_copy.sqlite"
        shutil.copy2(db_src, db_tmp)

    try:
        files, stats = _collect_bundle_files(slug, db_tmp)
        total_bytes = sum(src.stat().st_size for src, _, _ in files)
        done = 0
        if progress:
            progress(0, total_bytes)

        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for src, arcname, ctype in files:
                zinfo = zipfile.ZipInfo.from_file(src, arcname)
                zinfo.compress_type = ctype
                with open(src, "rb") as fin, zf.open(zinfo, "w", force_zip64=True) as out:
                    while True:
                        chunk = fin.read(_BUNDLE_CHUNK)
                        if not chunk:
                            break
                        out.write(chunk)
                        done += len(chunk)
                        if progress:
                            progress(done, total_bytes)

            manifest = {
                "app": "postpod",
                "version": 2,
                "slug": slug,
                "name": meta.get("name", slug),
                "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "file_count": len(files),
                "total_size_bytes": total_bytes,
                "includes": ["proyecto.json", "proyecto.sqlite", "media",
                             "branding", "sponsors", "sounds", "guests",
                             "director_assets", "global_audio"],
                "director_assets_count": stats["director_assets_count"],
                "global_audio_count": stats["global_audio_count"],
                "recovered_from_global": stats["recovered_from_global"],
            }
            zf.writestr("manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False))

        os.replace(tmp_path, zip_path)
    finally:
        if db_tmp is not None:
            db_tmp.unlink(missing_ok=True)
        tmp_path.unlink(missing_ok=True)  # only present if the build failed

    return zip_path


# ---------------------------------------------------------------------------
# Bundle freshness + background build job
# ---------------------------------------------------------------------------

def _latest_source_mtime(slug: str) -> float:
    """Newest mtime of anything that goes into the bundle: every project file
    except exports/, plus the global audio library."""
    project_dir = PROJECTS_DIR / slug
    latest = 0.0
    for child in project_dir.iterdir():
        if child.name == "exports":
            continue
        if child.is_file():
            latest = max(latest, child.stat().st_mtime)
        elif child.is_dir():
            for f in child.rglob("*"):
                if f.is_file():
                    latest = max(latest, f.stat().st_mtime)
    global_audio_dir = GLOBAL_DIR / "audio"
    if global_audio_dir.exists():
        for f in global_audio_dir.rglob("*"):
            if f.is_file():
                latest = max(latest, f.stat().st_mtime)
    return latest


def bundle_is_current(slug: str) -> bool:
    zip_path = bundle_zip_path(slug)
    if not zip_path.exists():
        return False
    return zip_path.stat().st_mtime > _latest_source_mtime(slug)


def _zip_version(zip_path: Path) -> str:
    st = zip_path.stat()
    return f"{int(st.st_mtime)}-{st.st_size}"


def _read_bundle_status(slug: str):
    try:
        return json.loads(_bundle_status_path(slug).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _write_bundle_status(slug: str, data: dict):
    # On file, not in memory: with several gunicorn workers any of them can
    # answer the GET while another worker's thread does the build.
    path = _bundle_status_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def bundle_status(slug: str) -> dict:
    st = _read_bundle_status(slug)
    if st and st.get("state") == "building":
        if time.time() - st.get("updated_at", 0) <= _JOB_STALE_SECS:
            return {"state": "building", "progress": st.get("progress", 0.0)}
        return {"state": "error", "progress": st.get("progress", 0.0),
                "error": "el trabajo anterior se interrumpió; vuelve a pedir el paquete"}
    zip_path = bundle_zip_path(slug)
    if bundle_is_current(slug):
        return {"state": "ready", "progress": 1.0,
                "size": zip_path.stat().st_size, "version": _zip_version(zip_path)}
    if st and st.get("state") == "error":
        return {"state": "error", "progress": st.get("progress", 0.0),
                "error": st.get("error", "")}
    return {"state": "idle", "progress": 0.0}


def _run_bundle_job(slug: str, lock_path: Path):
    last_tick = 0.0

    def cb(done, total):
        nonlocal last_tick
        now = time.time()
        if now - last_tick < 0.3 and done < total:
            return  # throttle status writes; the heartbeat only needs ~3/s
        last_tick = now
        pct = (done / total) if total else 1.0
        _write_bundle_status(slug, {"state": "building",
                                    "progress": round(min(pct, 1.0), 4),
                                    "updated_at": now})

    try:
        zip_path = export_project(slug, progress=cb)
        _write_bundle_status(slug, {"state": "ready", "progress": 1.0,
                                    "size": zip_path.stat().st_size,
                                    "version": _zip_version(zip_path),
                                    "updated_at": time.time()})
    except Exception as e:  # noqa: BLE001 — the error goes to the client
        _write_bundle_status(slug, {"state": "error", "progress": 0.0,
                                    "error": str(e), "updated_at": time.time()})
    finally:
        lock_path.unlink(missing_ok=True)


def start_bundle_build(slug: str) -> dict:
    """One build at a time per project. Returns the status the client should
    see right now: ready (nothing to do), building (ours or someone else's),
    or the fresh 'building' of the job this call just started."""
    current = bundle_status(slug)
    if current["state"] in ("ready", "building"):
        return current

    lock_path = _bundle_status_path(slug).with_name("_bundle_build.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
            break
        except FileExistsError:
            st = _read_bundle_status(slug)
            if st and st.get("state") == "building" \
                    and time.time() - st.get("updated_at", 0) <= _JOB_STALE_SECS:
                return {"state": "building", "progress": st.get("progress", 0.0)}
            lock_path.unlink(missing_ok=True)  # dead worker's lock: steal it
    else:
        return {"state": "error", "progress": 0.0,
                "error": "no se pudo iniciar el trabajo (lock ocupado)"}

    _write_bundle_status(slug, {"state": "building", "progress": 0.0,
                                "updated_at": time.time()})
    threading.Thread(target=_run_bundle_job, args=(slug, lock_path),
                     daemon=True).start()
    return {"state": "building", "progress": 0.0}


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
