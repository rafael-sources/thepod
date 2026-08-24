import sqlite3
from pathlib import Path

from config import SESSIONS_DIR, BASE_DIR


# Main DB: sessions catalogue and anything cross-session.
MAIN_DB_PATH = BASE_DIR / "main.sqlite"


MAIN_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    title                   TEXT NOT NULL,
    description             TEXT,
    status                  TEXT NOT NULL DEFAULT 'preparing'
        CHECK(status IN ('preparing', 'live', 'recording', 'finished', 'archived')),
    max_participants        INTEGER NOT NULL DEFAULT 4,
    created_by              TEXT NOT NULL,
    shared_project_id       TEXT,
    livekit_room_name       TEXT UNIQUE,
    started_at              TEXT,
    finished_at             TEXT,
    total_duration_seconds  INTEGER,
    recording_location      TEXT,
    is_public               INTEGER DEFAULT 0,
    created_at              TEXT DEFAULT (datetime('now')),
    updated_at              TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS participants (
    id                         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id                 INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    username                   TEXT,
    display_name               TEXT NOT NULL,
    invite_token               TEXT UNIQUE NOT NULL,
    role                       TEXT NOT NULL DEFAULT 'guest'
        CHECK(role IN ('host', 'co-host', 'guest', 'director')),
    status                     TEXT NOT NULL DEFAULT 'invited'
        CHECK(status IN ('invited', 'connected', 'active', 'disconnected', 'left')),
    joined_at                  TEXT,
    left_at                    TEXT,
    recording_video_path       TEXT,
    recording_audio_path       TEXT,
    recording_duration_seconds INTEGER,
    microphone_device          TEXT,
    camera_device              TEXT,
    audio_level_peak           REAL,
    is_muted                   INTEGER DEFAULT 0,
    is_camera_off              INTEGER DEFAULT 0,
    created_at                 TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_participants_session ON participants(session_id);

CREATE TABLE IF NOT EXISTS sound_effects (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id         INTEGER REFERENCES sessions(id) ON DELETE CASCADE,
    name               TEXT NOT NULL,
    filename           TEXT NOT NULL,
    is_default         INTEGER DEFAULT 1,
    shortcut_key       TEXT,
    duration_seconds   REAL,
    file_size_bytes    INTEGER,
    color              TEXT,
    created_at         TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS stream_config (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    platform   TEXT NOT NULL CHECK(platform IN ('youtube', 'twitch', 'custom')),
    rtmp_url   TEXT NOT NULL,
    stream_key TEXT NOT NULL,
    is_active  INTEGER DEFAULT 0,
    start_time TEXT,
    end_time   TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS recordings (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id        INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id    INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    track_type        TEXT NOT NULL,
    filename          TEXT NOT NULL,
    file_path         TEXT NOT NULL,
    duration_seconds  REAL,
    size_bytes        INTEGER,
    mime_type         TEXT,
    bitrate_kbps      INTEGER,
    resolution        TEXT,
    codec             TEXT,
    exported_to_postpod_at TEXT,
    created_at        TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_recordings_session ON recordings(session_id);

CREATE TABLE IF NOT EXISTS chat_messages (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    author_name    TEXT,
    message_text   TEXT NOT NULL,
    timestamp      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_chat_session ON chat_messages(session_id);

CREATE TABLE IF NOT EXISTS chapter_markers (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id        INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id    INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    label             TEXT,
    tl_offset_seconds REAL NOT NULL,
    created_at        TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_chapter_markers_session ON chapter_markers(session_id);

CREATE TABLE IF NOT EXISTS sound_triggers (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id        INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id    INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    sound_filename    TEXT NOT NULL,
    tl_offset_seconds REAL NOT NULL,
    triggered_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_sound_triggers_session ON sound_triggers(session_id);

CREATE TABLE IF NOT EXISTS live_streams (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    platform    TEXT,
    rtmp_url    TEXT NOT NULL,
    stream_key  TEXT NOT NULL,
    egress_id   TEXT,
    status      TEXT NOT NULL DEFAULT 'starting',
    started_by  TEXT,
    started_at  TEXT DEFAULT (datetime('now')),
    stopped_at  TEXT,
    error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_live_streams_session ON live_streams(session_id);

CREATE TABLE IF NOT EXISTS podcast_directors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    shared_project_id TEXT NOT NULL,
    assigned_by TEXT NOT NULL,
    assigned_at DATETIME DEFAULT (datetime('now')),
    UNIQUE(username, shared_project_id)
);

CREATE TABLE IF NOT EXISTS director_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    file_path TEXT,
    injected_at DATETIME DEFAULT (datetime('now')),
    recording_offset_seconds REAL,
    duration_seconds REAL,
    created_by TEXT NOT NULL,
    removed_at DATETIME
);
CREATE INDEX IF NOT EXISTS idx_director_events_session ON director_events(session_id);
"""


def _ensure_column(conn, table: str, column: str, ddl: str):
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    if not any(r["name"] == column for r in rows):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")


def get_db() -> sqlite3.Connection:
    MAIN_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(MAIN_DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(MAIN_SCHEMA)
    # Lazy in-place migrations for columns added after initial schema
    _ensure_column(conn, "sessions", "source_url", "source_url TEXT")
    _ensure_column(conn, "sessions", "source_slug", "source_slug TEXT")
    _ensure_column(conn, "sessions", "source_episode_id", "source_episode_id INTEGER")
    _ensure_column(conn, "chapter_markers", "is_planned", "is_planned INTEGER NOT NULL DEFAULT 0")
    _ensure_column(conn, "chapter_markers", "kind", "kind TEXT")
    _ensure_column(conn, "chapter_markers", "sponsor_name", "sponsor_name TEXT")
    _ensure_column(conn, "chapter_markers", "sponsor_copy", "sponsor_copy TEXT")
    _ensure_column(conn, "chapter_markers", "sponsor_logo_url", "sponsor_logo_url TEXT")
    _ensure_column(conn, "chapter_markers", "planned_offset_seconds", "planned_offset_seconds REAL")
    _ensure_column(conn, "chat_messages", "channel", "channel TEXT NOT NULL DEFAULT 'main'")
    _ensure_column(conn, "sound_effects", "director_only", "director_only INTEGER DEFAULT 0")
    _ensure_column(conn, "sound_triggers", "triggered_by", "triggered_by TEXT")
    _ensure_column(conn, "chat_messages", "target_username", "target_username TEXT")
    _migrate_participants_check(conn)
    return conn


def _migrate_participants_check(conn):
    """Fix FK references broken by the participants table rename migration.
    Already applied via _fix_fk.sql — this check is kept for safety."""
    for table in ("chat_messages", "recordings", "sound_triggers", "chapter_markers"):
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone()
        if row and "_participants_old" in (row["sql"] or ""):
            raise RuntimeError(
                f"Table {table} has broken FK to _participants_old. "
                "Run: sqlite3 main.sqlite < _fix_fk.sql"
            )


def session_dir(session_id: int) -> Path:
    d = SESSIONS_DIR / str(session_id)
    d.mkdir(parents=True, exist_ok=True)
    (d / "recordings").mkdir(exist_ok=True)
    (d / "sounds").mkdir(exist_ok=True)
    return d
