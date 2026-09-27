"""
Import/export recording sessions as ZIP bundles.

Export extracts session-specific data from the central DB into a standalone
SQLite, bundled with recordings and custom sounds.

ZIP structure:
    manifest.json           — app identifier, version, metadata
    session.sqlite          — standalone DB with session + related rows
    recordings/             — audio/video recording files
    sounds/                 — custom (non-default) sound effects
"""

import json
import shutil
import sqlite3
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from config import SESSIONS_DIR

SESSION_TABLES = [
    "sessions", "participants", "sound_effects", "recordings",
    "chat_messages", "chapter_markers", "sound_triggers",
    "live_streams", "stream_config",
]


def export_session(session_id: int) -> Path:
    from db import get_db

    main_db = get_db()
    try:
        session = main_db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        if not session:
            raise FileNotFoundError(f"sesión no encontrada: {session_id}")

        session_dir = SESSIONS_DIR / str(session_id)
        session_dir.mkdir(parents=True, exist_ok=True)
        zip_path = session_dir / f"session_{session_id}_bundle.zip"

        standalone_path = session_dir / "_export_tmp.sqlite"
        _extract_session_db(main_db, session_id, standalone_path)

        file_count = 0
        total_size = 0

        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(standalone_path, "session.sqlite")
            file_count += 1

            rec_dir = session_dir / "recordings"
            if rec_dir.exists():
                for f in rec_dir.rglob("*"):
                    if f.is_file():
                        arcname = f"recordings/{f.relative_to(rec_dir)}"
                        zf.write(f, arcname)
                        total_size += f.stat().st_size
                        file_count += 1

            sounds_dir = session_dir / "sounds"
            if sounds_dir.exists():
                for f in sounds_dir.rglob("*"):
                    if f.is_file():
                        arcname = f"sounds/{f.relative_to(sounds_dir)}"
                        zf.write(f, arcname)
                        total_size += f.stat().st_size
                        file_count += 1

            manifest = {
                "app": "prodpod",
                "version": 1,
                "session_id": session_id,
                "title": session["title"],
                "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "file_count": file_count,
                "total_size_bytes": total_size,
            }
            zf.writestr("manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False))

        standalone_path.unlink(missing_ok=True)
        return zip_path
    finally:
        main_db.close()


def _extract_session_db(main_db, session_id: int, dest: Path):
    """Copy session-specific rows from the central DB into a standalone SQLite."""
    if dest.exists():
        dest.unlink()

    from db import MAIN_SCHEMA
    conn = sqlite3.connect(str(dest))
    conn.execute("PRAGMA foreign_keys = OFF")
    conn.executescript(MAIN_SCHEMA)

    for table in SESSION_TABLES:
        cols_info = main_db.execute(f"PRAGMA table_info({table})").fetchall()
        if not cols_info:
            continue

        has_session_id = any(c["name"] == "session_id" for c in cols_info)
        if table == "sessions":
            rows = main_db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchall()
        elif has_session_id:
            rows = main_db.execute(f"SELECT * FROM {table} WHERE session_id=?", (session_id,)).fetchall()
        else:
            continue

        if not rows:
            continue

        col_names = [c["name"] for c in cols_info]
        placeholders = ", ".join("?" * len(col_names))
        cols_str = ", ".join(col_names)
        for row in rows:
            values = [row[c] for c in col_names]
            conn.execute(f"INSERT OR IGNORE INTO {table} ({cols_str}) VALUES ({placeholders})", values)

    conn.commit()
    conn.close()


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
                if manifest.get("app") != "prodpod":
                    errors.append("archivo no es una sesión prodPod válida")
            except (json.JSONDecodeError, KeyError):
                errors.append("manifest.json corrupto")
        if "session.sqlite" not in names:
            errors.append("falta session.sqlite")
        else:
            import tempfile
            with tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False) as tmp:
                tmp.write(zf.read("session.sqlite"))
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


def import_session(zip_path: Path, owner_username: str | None = None) -> dict:
    """Import a session bundle, merging data into the central DB."""
    import tempfile
    from db import get_db

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(tmp)

        standalone = tmp / "session.sqlite"
        if not standalone.exists():
            raise FileNotFoundError("falta session.sqlite en el ZIP")

        src = sqlite3.connect(str(standalone))
        src.row_factory = sqlite3.Row

        src_session = src.execute("SELECT * FROM sessions LIMIT 1").fetchone()
        if not src_session:
            src.close()
            raise ValueError("no hay sesión en el archivo importado")

        main_db = get_db()
        try:
            cols_info = main_db.execute("PRAGMA table_info(sessions)").fetchall()
            col_names = [c["name"] for c in cols_info if c["name"] != "id"]
            src_col_names = [c["name"] for c in src.execute("PRAGMA table_info(sessions)").fetchall()]
            shared_cols = [c for c in col_names if c in src_col_names]

            placeholders = ", ".join("?" * len(shared_cols))
            cols_str = ", ".join(shared_cols)
            values = [src_session[c] for c in shared_cols]
            if owner_username and "created_by" in shared_cols:
                idx = shared_cols.index("created_by")
                values[idx] = owner_username

            cur = main_db.execute(
                f"INSERT INTO sessions ({cols_str}) VALUES ({placeholders})", values
            )
            new_session_id = cur.lastrowid

            old_id = src_session["id"]

            for table in SESSION_TABLES:
                if table == "sessions":
                    continue
                src_cols = [c["name"] for c in src.execute(f"PRAGMA table_info({table})").fetchall()]
                if "session_id" not in src_cols:
                    continue

                main_cols = [c["name"] for c in main_db.execute(f"PRAGMA table_info({table})").fetchall()]
                shared = [c for c in main_cols if c in src_cols and c != "id"]

                rows = src.execute(f"SELECT * FROM {table} WHERE session_id=?", (old_id,)).fetchall()
                for row in rows:
                    vals = []
                    for c in shared:
                        v = row[c]
                        if c == "session_id":
                            v = new_session_id
                        vals.append(v)
                    ph = ", ".join("?" * len(shared))
                    cs = ", ".join(shared)
                    main_db.execute(f"INSERT INTO {table} ({cs}) VALUES ({ph})", vals)

            main_db.commit()

            session_dir = SESSIONS_DIR / str(new_session_id)
            for subdir in ("recordings", "sounds"):
                src_dir = tmp / subdir
                if src_dir.exists():
                    dst_dir = session_dir / subdir
                    dst_dir.mkdir(parents=True, exist_ok=True)
                    for f in src_dir.rglob("*"):
                        if f.is_file():
                            dest = dst_dir / f.relative_to(src_dir)
                            dest.parent.mkdir(parents=True, exist_ok=True)
                            shutil.copy2(f, dest)

        finally:
            main_db.close()
            src.close()

    return {"session_id": new_session_id}
