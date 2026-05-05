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
        CHECK(status IN ('idea', 'planning', 'scripted', 'recorded', 'published', 'archived')),
    scheduled_date    TEXT,
    duration_estimate REAL,
    created_at        TEXT DEFAULT (datetime('now')),
    updated_at        TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_episodes_status ON episodes(status);

CREATE TABLE IF NOT EXISTS episode_guests (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id      INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    email           TEXT,
    role            TEXT NOT NULL DEFAULT 'guest'
                    CHECK(role IN ('host', 'co-host', 'guest')),
    bio             TEXT,
    rsvp_status     TEXT NOT NULL DEFAULT 'pending'
                    CHECK(rsvp_status IN ('pending', 'yes', 'no', 'maybe')),
    invite_url      TEXT,
    invite_token    TEXT,
    created_at      TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_episode_guests_episode ON episode_guests(episode_id);

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

CREATE TABLE IF NOT EXISTS podcast_sounds (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    filename          TEXT NOT NULL,
    shortcut_key      TEXT,
    color             TEXT,
    duration_seconds  REAL,
    file_size_bytes   INTEGER,
    position          INTEGER NOT NULL DEFAULT 0,
    created_at        TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_podcast_sounds_pos ON podcast_sounds(position);

CREATE TABLE IF NOT EXISTS episode_blocks (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id         INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    position           INTEGER NOT NULL,
    kind               TEXT NOT NULL DEFAULT 'segment'
                       CHECK(kind IN ('intro', 'segment', 'interview', 'sponsor', 'break', 'outro', 'custom')),
    title              TEXT NOT NULL DEFAULT '',
    duration_estimate  REAL,
    notes              TEXT,
    created_at         TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_blocks_episode_pos ON episode_blocks(episode_id, position);

CREATE TABLE IF NOT EXISTS sponsors (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    copy         TEXT NOT NULL DEFAULT '',
    url          TEXT,
    notes        TEXT,
    is_active    INTEGER NOT NULL DEFAULT 1,
    position     INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT DEFAULT (datetime('now')),
    updated_at   TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_sponsors_pos ON sponsors(position);

CREATE TABLE IF NOT EXISTS templates (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    description  TEXT,
    is_default   INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT DEFAULT (datetime('now')),
    updated_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS template_blocks (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id        INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
    position           INTEGER NOT NULL,
    kind               TEXT NOT NULL DEFAULT 'segment'
                       CHECK(kind IN ('intro', 'segment', 'interview', 'sponsor', 'break', 'outro', 'custom')),
    title              TEXT NOT NULL DEFAULT '',
    duration_estimate  REAL,
    notes              TEXT,
    created_at         TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_template_blocks_pos ON template_blocks(template_id, position);

CREATE TABLE IF NOT EXISTS template_sections (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id        INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
    position           INTEGER NOT NULL,
    speaker            TEXT,
    content            TEXT NOT NULL DEFAULT '',
    estimated_duration REAL,
    notes              TEXT,
    created_at         TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_template_sections_pos ON template_sections(template_id, position);

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


def _ensure_column(conn, table: str, column: str, ddl: str):
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    if not any(r["name"] == column for r in rows):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")


def get_db(slug: str) -> sqlite3.Connection:
    path = podcast_db_path(slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    # Lazy in-place migrations for columns added after initial schema
    _ensure_column(conn, "episodes", "production_status", "production_status TEXT")
    _ensure_column(conn, "episodes", "production_meta", "production_meta TEXT")
    _ensure_column(conn, "episodes", "production_updated_at", "production_updated_at TEXT")
    _ensure_column(conn, "episodes", "scheduled_at", "scheduled_at TEXT")
    _ensure_column(conn, "podcast_meta", "owner_username", "owner_username TEXT")
    _ensure_column(conn, "podcast_meta", "extra_hosts", "extra_hosts TEXT")  # JSON array of usernames
    _ensure_column(conn, "podcast_meta", "host_invitations", "host_invitations TEXT")  # JSON {username: {status, invited_by, invited_at, email_sent}}
    _ensure_column(conn, "podcast_meta", "color_bg", "color_bg TEXT")
    _ensure_column(conn, "podcast_meta", "color_text", "color_text TEXT")
    _ensure_column(conn, "podcast_meta", "color_text_align", "color_text_align TEXT")  # left|center|right|justify
    _ensure_column(conn, "podcast_meta", "rss_override_url", "rss_override_url TEXT")
    _ensure_column(conn, "podcast_meta", "landing_blocks", "landing_blocks TEXT")  # Editor.js JSON
    _ensure_column(conn, "episodes", "landing_position", "landing_position INTEGER")
    # RSVP-by-email token (separate from invite_token, which is owned by
    # prodPod for the recording-room join URL). Lazy-populated by episodes.py
    # when guests are created/listed; UNIQUE INDEX ignores NULLs in SQLite.
    _ensure_column(conn, "episode_guests", "rsvp_token", "rsvp_token TEXT")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_episode_guests_rsvp_token ON episode_guests(rsvp_token)")
    # Sponsors: podcast-level table + per-block link.
    _ensure_column(conn, "episode_blocks", "sponsor_id", "sponsor_id INTEGER REFERENCES sponsors(id) ON DELETE SET NULL")
    # Guest social handles + photo for speaker banners in postPod exports.
    _ensure_column(conn, "episode_guests", "social_instagram", "social_instagram TEXT")
    _ensure_column(conn, "episode_guests", "social_twitter", "social_twitter TEXT")
    _ensure_column(conn, "episode_guests", "social_youtube", "social_youtube TEXT")
    _ensure_column(conn, "episode_guests", "social_tiktok", "social_tiktok TEXT")
    _ensure_column(conn, "episode_guests", "photo_filename", "photo_filename TEXT")
    # Sponsor logo image for overlay banners.
    _ensure_column(conn, "sponsors", "logo_filename", "logo_filename TEXT")
    # Planned offset (seconds from episode start) for sponsor moments.
    _ensure_column(conn, "episode_blocks", "planned_offset_seconds", "planned_offset_seconds INTEGER")
    # Team members: extend with youtube + tiktok to match guest social fields.
    _ensure_column(conn, "team_members", "social_youtube", "social_youtube TEXT")
    _ensure_column(conn, "team_members", "social_tiktok", "social_tiktok TEXT")
    _ensure_column(conn, "podcast_meta", "background_filename", "background_filename TEXT")
    _ensure_column(conn, "episodes", "ai_summary", "ai_summary TEXT")
    _ensure_column(conn, "episodes", "ai_highlights", "ai_highlights TEXT")
    _ensure_column(conn, "episodes", "ai_notes_edited", "ai_notes_edited INTEGER DEFAULT 0")
    _ensure_column(conn, "episodes", "ai_notes_synced_at", "ai_notes_synced_at TEXT")
    _ensure_column(conn, "episodes", "media_url", "media_url TEXT")
    _migrate_episodes_check_archived(conn)
    return conn


def _migrate_episodes_check_archived(conn):
    try:
        conn.execute("INSERT INTO episodes (title, status) VALUES ('__test__', 'archived')")
        conn.execute("DELETE FROM episodes WHERE title = '__test__' AND status = 'archived'")
        conn.commit()
    except sqlite3.IntegrityError:
        conn.rollback()
        conn.executescript("""
            CREATE TABLE episodes_new (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                episode_number       INTEGER,
                title                TEXT NOT NULL,
                description          TEXT,
                status               TEXT NOT NULL DEFAULT 'idea'
                    CHECK(status IN ('idea', 'planning', 'scripted', 'recorded', 'published', 'archived')),
                scheduled_date       TEXT,
                duration_estimate    REAL,
                created_at           TEXT DEFAULT (datetime('now')),
                updated_at           TEXT DEFAULT (datetime('now')),
                production_status    TEXT,
                production_meta      TEXT,
                production_updated_at TEXT,
                scheduled_at         TEXT,
                landing_position     INTEGER
            );
            INSERT INTO episodes_new
                SELECT id, episode_number, title, description, status,
                       scheduled_date, duration_estimate, created_at, updated_at,
                       production_status, production_meta, production_updated_at,
                       scheduled_at, landing_position
                FROM episodes;
            DROP TABLE episodes;
            ALTER TABLE episodes_new RENAME TO episodes;
            CREATE INDEX IF NOT EXISTS idx_episodes_status ON episodes(status);
        """)
        conn.commit()
