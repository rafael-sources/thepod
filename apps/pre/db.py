import sqlite3
from pathlib import Path

from config import PODCASTS_DIR


SCHEMA = """
CREATE TABLE IF NOT EXISTS podcast_meta (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    slug              TEXT NOT NULL UNIQUE,
    description       TEXT,
    tagline           TEXT,
    color_primary     TEXT DEFAULT '#5a8bff',
    color_secondary   TEXT DEFAULT '#1e2a54',
    color_accent      TEXT DEFAULT '#f4c770',
    font_heading      TEXT DEFAULT 'Fraunces',
    font_body         TEXT DEFAULT 'Bricolage Grotesque',
    logo_filename     TEXT,
    cover_filename    TEXT,
    shared_project_id TEXT UNIQUE,
    created_at        TEXT DEFAULT (datetime('now')),
    updated_at        TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS branding_history (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    field_name TEXT NOT NULL,
    old_value  TEXT,
    new_value  TEXT,
    changed_by TEXT,
    changed_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS episodes (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_number    INTEGER,
    title             TEXT NOT NULL,
    description       TEXT,
    status            TEXT NOT NULL DEFAULT 'idea'
        CHECK(status IN ('idea', 'planning', 'scripted', 'recorded', 'published')),
    scheduled_date    TEXT,
    duration_estimate REAL,
    created_at        TEXT DEFAULT (datetime('now')),
    updated_at        TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_episodes_status ON episodes(status);

CREATE TABLE IF NOT EXISTS ideas (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    content    TEXT NOT NULL,
    author     TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'proposed'
        CHECK(status IN ('proposed', 'accepted', 'rejected')),
    votes      INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_ideas_episode ON ideas(episode_id);

CREATE TABLE IF NOT EXISTS idea_votes (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id  INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    username TEXT NOT NULL,
    UNIQUE(idea_id, username)
);

CREATE TABLE IF NOT EXISTS script_sections (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id         INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    position           INTEGER NOT NULL,
    speaker            TEXT,
    content            TEXT NOT NULL DEFAULT '',
    estimated_duration REAL,
    notes              TEXT,
    created_at         TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_script_episode_pos ON script_sections(episode_id, position);

CREATE TABLE IF NOT EXISTS landing_config (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    template              TEXT NOT NULL DEFAULT 'minimal'
        CHECK(template IN ('minimal', 'bold', 'classic')),
    custom_css            TEXT,
    show_episodes         INTEGER DEFAULT 1,
    show_team             INTEGER DEFAULT 0,
    owner_name            TEXT,
    owner_email           TEXT,
    language              TEXT DEFAULT 'es',
    social_youtube        TEXT,
    social_spotify        TEXT,
    social_apple_podcasts TEXT,
    social_instagram      TEXT,
    social_tiktok         TEXT,
    social_twitter        TEXT,
    analytics_code        TEXT,
    og_image_url          TEXT,
    created_at            TEXT DEFAULT (datetime('now')),
    updated_at            TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS episode_links (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    platform   TEXT NOT NULL,
    url        TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    UNIQUE(episode_id, platform)
);

CREATE TABLE IF NOT EXISTS team_members (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    name             TEXT NOT NULL,
    role             TEXT,
    bio              TEXT,
    image_filename   TEXT,
    social_twitter   TEXT,
    social_instagram TEXT,
    social_website   TEXT,
    position         INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT DEFAULT (datetime('now'))
);
"""


def podcast_db_path(slug: str) -> Path:
    return PODCASTS_DIR / slug / "proyecto.sqlite"


def get_db(slug: str) -> sqlite3.Connection:
    path = podcast_db_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    return conn
