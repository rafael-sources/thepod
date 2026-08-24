PRAGMA foreign_keys = OFF;

-- chat_messages
ALTER TABLE chat_messages RENAME TO _chat_messages_old;
CREATE TABLE chat_messages (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    author_name    TEXT,
    message_text   TEXT NOT NULL,
    timestamp      TEXT DEFAULT (datetime('now')),
    channel        TEXT NOT NULL DEFAULT 'main',
    target_username TEXT
);
INSERT INTO chat_messages SELECT * FROM _chat_messages_old;
DROP TABLE _chat_messages_old;

-- recordings
ALTER TABLE recordings RENAME TO _recordings_old;
CREATE TABLE recordings (
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
INSERT INTO recordings SELECT * FROM _recordings_old;
DROP TABLE _recordings_old;

-- sound_triggers
ALTER TABLE sound_triggers RENAME TO _sound_triggers_old;
CREATE TABLE sound_triggers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id  INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    sound_filename  TEXT NOT NULL,
    tl_offset_seconds REAL NOT NULL,
    triggered_at    TEXT DEFAULT (datetime('now')),
    triggered_by    TEXT
);
INSERT INTO sound_triggers SELECT * FROM _sound_triggers_old;
DROP TABLE _sound_triggers_old;

-- chapter_markers
ALTER TABLE chapter_markers RENAME TO _chapter_markers_old;
CREATE TABLE chapter_markers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    participant_id  INTEGER REFERENCES participants(id) ON DELETE SET NULL,
    label           TEXT,
    tl_offset_seconds REAL NOT NULL,
    created_at      TEXT DEFAULT (datetime('now')),
    is_planned      INTEGER NOT NULL DEFAULT 0,
    kind            TEXT,
    sponsor_name    TEXT,
    sponsor_copy    TEXT,
    sponsor_logo_url TEXT,
    planned_offset_seconds REAL
);
INSERT INTO chapter_markers SELECT * FROM _chapter_markers_old;
DROP TABLE _chapter_markers_old;

PRAGMA foreign_keys = ON;
