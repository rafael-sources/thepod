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
        CHECK(role IN ('host', 'co-host', 'guest')),
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
"""


def get_db() -> sqlite3.Connection:
    MAIN_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(MAIN_DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(MAIN_SCHEMA)
    return conn


def session_dir(session_id: int) -> Path:
    d = SESSIONS_DIR / str(session_id)
    d.mkdir(parents=True, exist_ok=True)
    (d / "recordings").mkdir(exist_ok=True)
    (d / "sounds").mkdir(exist_ok=True)
    return d
