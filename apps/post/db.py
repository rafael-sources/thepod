import sqlite3
from pathlib import Path

from config import PROJECTS_DIR


SCHEMA = """
CREATE TABLE IF NOT EXISTS media_files (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    filename      TEXT NOT NULL,
    original_name TEXT NOT NULL,
    file_type     TEXT NOT NULL,
    duration      REAL,
    size_bytes    INTEGER,
    created_at    TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS project_meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS timeline_clips (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    position      INTEGER NOT NULL,
    media_file_id INTEGER REFERENCES media_files(id) ON DELETE CASCADE,
    label         TEXT,
    start_offset  REAL NOT NULL DEFAULT 0,
    end_offset    REAL,
    track         INTEGER NOT NULL DEFAULT 1,
    volume        REAL NOT NULL DEFAULT 1.0,
    created_at    TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_timeline_clips_position ON timeline_clips(position);

CREATE TABLE IF NOT EXISTS moments (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    type              TEXT NOT NULL CHECK(type IN ('relative', 'absolute')),
    timeline_seconds  REAL NOT NULL,
    label             TEXT,
    created_at        TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS operations (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    moment_id  INTEGER NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    type       TEXT NOT NULL,
    params     TEXT NOT NULL DEFAULT '{}',
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_operations_moment_id ON operations(moment_id);

CREATE TABLE IF NOT EXISTS audio_lane_clips (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    media_file_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    label         TEXT,
    tl_start      REAL NOT NULL DEFAULT 0,
    start_offset  REAL NOT NULL DEFAULT 0,
    end_offset    REAL,
    volume        REAL NOT NULL DEFAULT 0.7,
    created_at    TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_audio_lane_clips_start ON audio_lane_clips(tl_start);

CREATE TABLE IF NOT EXISTS export_jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    preset_id   TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    output_file TEXT,
    error_msg   TEXT,
    progress    INTEGER DEFAULT 0,
    started_at  TEXT,
    finished_at TEXT,
    burn_captions_json TEXT,
    created_at  TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_export_jobs_status ON export_jobs(status);
"""


def project_db_path(slug: str) -> Path:
    return PROJECTS_DIR / slug / "proyecto.sqlite"


def get_db(slug: str) -> sqlite3.Connection:
    path = project_db_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    _migrate_in_place(conn)
    return conn


def _migrate_in_place(conn: sqlite3.Connection) -> None:
    """Apply idempotent ALTER TABLE migrations for schema fields added after
    a project's DB was first created. CREATE TABLE IF NOT EXISTS won't update
    pre-existing tables."""
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(timeline_clips)")}
    if "track" not in cols:
        conn.execute("ALTER TABLE timeline_clips ADD COLUMN track INTEGER NOT NULL DEFAULT 1")
    if "volume" not in cols:
        conn.execute("ALTER TABLE timeline_clips ADD COLUMN volume REAL NOT NULL DEFAULT 1.0")
    ej_cols = {r["name"] for r in conn.execute("PRAGMA table_info(export_jobs)")}
    if "burn_captions_json" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN burn_captions_json TEXT")
    conn.commit()
