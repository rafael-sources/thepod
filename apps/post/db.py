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

CREATE TABLE IF NOT EXISTS transcript_cuts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    start_seconds   REAL NOT NULL,
    end_seconds     REAL NOT NULL,
    label           TEXT,
    created_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_transcript_cuts_start ON transcript_cuts(start_seconds);

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

CREATE TABLE IF NOT EXISTS project_participants (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    role              TEXT NOT NULL DEFAULT 'guest',
    track             INTEGER,
    social_instagram  TEXT,
    social_twitter    TEXT,
    social_youtube    TEXT,
    social_tiktok     TEXT,
    photo_filename    TEXT,
    banner_shown_at   TEXT,
    created_at        TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS project_sponsors (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    copy            TEXT,
    url             TEXT,
    logo_filename   TEXT,
    position        INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS project_segments (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    position          INTEGER NOT NULL,
    kind              TEXT NOT NULL DEFAULT 'segment',
    title             TEXT NOT NULL DEFAULT '',
    duration_estimate REAL,
    sponsor_id        INTEGER REFERENCES project_sponsors(id) ON DELETE SET NULL,
    notes             TEXT,
    created_at        TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_project_segments_pos ON project_segments(position);
"""


def project_db_path(slug: str) -> Path:
    return PROJECTS_DIR / slug / "proyecto.sqlite"


def get_db(slug: str) -> sqlite3.Connection:
    path = project_db_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
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
    if "generate_notes" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN generate_notes INTEGER NOT NULL DEFAULT 0")
    if "notes_file" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN notes_file TEXT")
    if "enhance_speech" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN enhance_speech INTEGER NOT NULL DEFAULT 0")
    # range_start/range_end let an export render only a sub-segment of the
    # timeline (e.g. a TikTok clip from 10s to 70s) without losing internal
    # cuts/zooms applied within that range.
    if "range_start" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN range_start REAL")
    if "range_end" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN range_end REAL")
    if "spotlight" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN spotlight INTEGER NOT NULL DEFAULT 0")
    if "use_background" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN use_background INTEGER NOT NULL DEFAULT 0")
    if "moment_banner" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN moment_banner INTEGER NOT NULL DEFAULT 0")
    if "banner_position" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN banner_position TEXT DEFAULT 'bottom'")
    if "vertical_center_spotlight" not in ej_cols:
        conn.execute("ALTER TABLE export_jobs ADD COLUMN vertical_center_spotlight INTEGER NOT NULL DEFAULT 0")
    # Moment duration: lets the user define a moment as a range
    # [timeline_seconds .. timeline_seconds + duration_seconds] instead of
    # a point. Old rows stay NULL and are treated as point-in-time.
    m_cols = {r["name"] for r in conn.execute("PRAGMA table_info(moments)")}
    if "duration_seconds" not in m_cols:
        conn.execute("ALTER TABLE moments ADD COLUMN duration_seconds REAL")
    conn.commit()
