import sqlite3
from pathlib import Path
from config import EVENTS_DIR, BASE_DIR

MAIN_DB_PATH = BASE_DIR / "main.sqlite"

MAIN_SCHEMA = """\
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    status TEXT DEFAULT 'created' CHECK(status IN ('created','active','finished')),
    chat_mode TEXT DEFAULT 'free' CHECK(chat_mode IN ('free','moderated','off')),
    livekit_room_name TEXT UNIQUE,
    egress_id TEXT,
    recording_file TEXT,
    shared_project_id TEXT,
    prodpod_session_id INTEGER,
    branding_json TEXT,
    host_username TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    finished_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS participants (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES events(id),
    display_name TEXT NOT NULL,
    photo_url TEXT,
    access_token TEXT UNIQUE,
    status TEXT DEFAULT 'pending' CHECK(status IN ('pending','approved','in_queue','on_air','done','rejected','left')),
    queue_position INTEGER,
    livekit_identity TEXT,
    is_preconnected INTEGER DEFAULT 0,
    is_censored INTEGER DEFAULT 0,
    questions TEXT DEFAULT '[]',
    requested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    approved_at TIMESTAMP,
    turn_started_at TIMESTAMP,
    turn_ended_at TIMESTAMP,
    UNIQUE(event_id, display_name)
);
CREATE INDEX IF NOT EXISTS idx_participants_event ON participants(event_id);

CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES events(id),
    sender_name TEXT NOT NULL,
    is_host INTEGER DEFAULT 0,
    message TEXT NOT NULL,
    is_approved INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_chat_event ON chat_messages(event_id);

CREATE TABLE IF NOT EXISTS event_templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    chat_mode TEXT DEFAULT 'free',
    branding_json TEXT,
    host_username TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
"""

def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(str(MAIN_DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.executescript(MAIN_SCHEMA)
    _migrate(conn)
    return conn

def _migrate(conn):
    cur = conn.execute("PRAGMA table_info(participants)")
    cols = {r[1] for r in cur.fetchall()}
    if "questions" not in cols:
        conn.execute("ALTER TABLE participants ADD COLUMN questions TEXT DEFAULT '[]'")
        conn.commit()

def event_dir(event_id: int) -> Path:
    d = EVENTS_DIR / str(event_id)
    (d / "recordings").mkdir(parents=True, exist_ok=True)
    (d / "chat").mkdir(parents=True, exist_ok=True)
    return d
