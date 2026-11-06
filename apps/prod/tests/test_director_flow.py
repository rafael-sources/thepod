"""Integration test: Director assignment → join → inject → cue → export."""

import json

import pytest


@pytest.fixture
def setup_full(tmp_path):
    import config
    import db as db_mod

    db_path = tmp_path / "main.sqlite"
    config.BASE_DIR = tmp_path
    config.SESSIONS_DIR = tmp_path / "sessions"
    config.SESSIONS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = db_path
    db_mod.SESSIONS_DIR = config.SESSIONS_DIR

    conn = db_mod.get_db()
    conn.execute(
        "INSERT INTO sessions (id, title, created_by, shared_project_id, livekit_room_name, status, started_at) "
        "VALUES (1, 'Live Ep', 'admin', 'proj-pod1', 'room_1', 'recording', datetime('now', '-10 minutes'))"
    )
    conn.execute(
        "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
        "VALUES (1, 'admin', 'Admin', 'tok-host', 'host', 'connected')"
    )
    conn.execute(
        "INSERT INTO podcast_directors (username, shared_project_id, assigned_by) "
        "VALUES ('carlos', 'proj-pod1', 'admin')"
    )
    conn.execute(
        "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
        "VALUES (1, 'carlos', 'Carlos', 'tok-dir', 'director', 'connected')"
    )
    conn.commit()
    conn.close()
    return tmp_path


def test_inject_and_query_events(setup_full):
    from db import get_db
    db = get_db()
    try:
        db.execute(
            "INSERT INTO director_events (session_id, event_type, payload, recording_offset_seconds, created_by) "
            "VALUES (1, 'banner', ?, 120.5, 'carlos')",
            (json.dumps({"name": "Ana", "title": "Experta"}),),
        )
        db.execute(
            "INSERT INTO director_events (session_id, event_type, payload, recording_offset_seconds, created_by) "
            "VALUES (1, 'cue', ?, 180.0, 'carlos')",
            (json.dumps({"cue": "WRAP UP", "target": "all"}),),
        )
        db.execute(
            "INSERT INTO director_events (session_id, event_type, payload, file_path, recording_offset_seconds, created_by) "
            "VALUES (1, 'graphic', ?, 'director_assets/meme.png', 200.0, 'carlos')",
            (json.dumps({"caption": "Meme del día"}),),
        )
        db.commit()

        events = db.execute("SELECT * FROM director_events WHERE session_id=1 ORDER BY recording_offset_seconds").fetchall()
        assert len(events) == 3
        assert events[0]["event_type"] == "banner"
        assert events[0]["recording_offset_seconds"] == 120.5
        assert json.loads(events[0]["payload"])["name"] == "Ana"
        assert events[1]["event_type"] == "cue"
        assert events[2]["file_path"] == "director_assets/meme.png"

        db.execute("UPDATE director_events SET removed_at=datetime('now') WHERE id=?", (events[0]["id"],))
        db.commit()
        removed = db.execute("SELECT removed_at FROM director_events WHERE id=?", (events[0]["id"],)).fetchone()
        assert removed["removed_at"] is not None
    finally:
        db.close()


def test_director_only_sounds(setup_full):
    from db import get_db
    db = get_db()
    try:
        db.execute(
            "INSERT INTO sound_effects (session_id, name, filename, director_only) VALUES (1, 'Aplauso', 'aplauso.mp3', 0)"
        )
        db.execute(
            "INSERT INTO sound_effects (session_id, name, filename, director_only) VALUES (1, 'Stinger', 'stinger.mp3', 1)"
        )
        db.commit()

        session_sounds = db.execute("SELECT * FROM sound_effects WHERE session_id=1 AND director_only=0").fetchall()
        director_sounds = db.execute("SELECT * FROM sound_effects WHERE session_id=1 AND director_only=1").fetchall()
        assert len(session_sounds) == 1
        assert len(director_sounds) == 1
        assert director_sounds[0]["name"] == "Stinger"
    finally:
        db.close()


def test_podcast_directors_scope(setup_full):
    from db import get_db
    from director_api import _is_director
    db = get_db()
    try:
        assert _is_director(db, 1, "carlos") is True
        assert _is_director(db, 1, "admin") is False

        directors = db.execute(
            "SELECT * FROM podcast_directors WHERE shared_project_id='proj-pod1'"
        ).fetchall()
        assert len(directors) == 1
        assert directors[0]["username"] == "carlos"

        directors2 = db.execute(
            "SELECT * FROM podcast_directors WHERE shared_project_id='proj-other'"
        ).fetchall()
        assert len(directors2) == 0
    finally:
        db.close()
