"""Tests for director_api endpoints."""

import json

import pytest


@pytest.fixture
def setup_db(tmp_path):
    """Set up a test database with director tables."""
    import config
    import db as db_mod

    db_path = tmp_path / "main.sqlite"
    config.BASE_DIR = tmp_path
    config.SESSIONS_DIR = tmp_path / "sessions"
    config.SESSIONS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = db_path
    db_mod.SESSIONS_DIR = config.SESSIONS_DIR

    conn = db_mod.get_db()

    # Create a session
    conn.execute(
        "INSERT INTO sessions (id, title, created_by, shared_project_id, livekit_room_name) "
        "VALUES (1, 'Test Session', 'host_user', 'proj-abc', 'room_1')"
    )
    # Create host participant
    conn.execute(
        "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
        "VALUES (1, 'host_user', 'Host', 'tok-host', 'host', 'connected')"
    )
    # Create director participant
    conn.execute(
        "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
        "VALUES (1, 'director_user', 'Director', 'tok-director', 'director', 'connected')"
    )
    # Create guest participant
    conn.execute(
        "INSERT INTO participants (session_id, username, display_name, invite_token, role, status) "
        "VALUES (1, 'guest_user', 'Guest', 'tok-guest', 'guest', 'connected')"
    )
    conn.commit()
    conn.close()
    return tmp_path


class TestPodcastDirectors:
    def test_assign_and_list(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            db.execute(
                "INSERT INTO podcast_directors (username, shared_project_id, assigned_by) VALUES (?, ?, ?)",
                ("carlos", "proj-abc", "host_user"),
            )
            db.commit()
            rows = db.execute("SELECT * FROM podcast_directors WHERE shared_project_id='proj-abc'").fetchall()
            assert len(rows) == 1
            assert rows[0]["username"] == "carlos"
        finally:
            db.close()

    def test_unique_constraint(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            db.execute(
                "INSERT INTO podcast_directors (username, shared_project_id, assigned_by) VALUES (?, ?, ?)",
                ("carlos", "proj-abc", "host_user"),
            )
            db.commit()
            db.execute(
                "INSERT OR IGNORE INTO podcast_directors (username, shared_project_id, assigned_by) VALUES (?, ?, ?)",
                ("carlos", "proj-abc", "host_user"),
            )
            db.commit()
            rows = db.execute("SELECT * FROM podcast_directors WHERE shared_project_id='proj-abc'").fetchall()
            assert len(rows) == 1
        finally:
            db.close()


class TestDirectorEvents:
    def test_inject_event(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            payload = json.dumps({"name": "Juan", "title": "Invitado"})
            db.execute(
                "INSERT INTO director_events (session_id, event_type, payload, created_by) "
                "VALUES (1, 'banner', ?, 'director_user')",
                (payload,),
            )
            db.commit()
            row = db.execute("SELECT * FROM director_events WHERE session_id=1").fetchone()
            assert row["event_type"] == "banner"
            assert json.loads(row["payload"])["name"] == "Juan"
            assert row["removed_at"] is None
        finally:
            db.close()

    def test_remove_event(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            db.execute(
                "INSERT INTO director_events (session_id, event_type, payload, created_by) "
                "VALUES (1, 'banner', '{}', 'director_user')"
            )
            db.commit()
            eid = db.execute("SELECT id FROM director_events ORDER BY id DESC LIMIT 1").fetchone()["id"]
            db.execute("UPDATE director_events SET removed_at=datetime('now') WHERE id=?", (eid,))
            db.commit()
            row = db.execute("SELECT * FROM director_events WHERE id=?", (eid,)).fetchone()
            assert row["removed_at"] is not None
        finally:
            db.close()

    def test_cue_event(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            payload = json.dumps({"cue": "WRAP UP", "text": "", "target": "all"})
            db.execute(
                "INSERT INTO director_events (session_id, event_type, payload, created_by) "
                "VALUES (1, 'cue', ?, 'director_user')",
                (payload,),
            )
            db.commit()
            row = db.execute("SELECT * FROM director_events WHERE event_type='cue'").fetchone()
            assert json.loads(row["payload"])["cue"] == "WRAP UP"
        finally:
            db.close()


class TestIsDirector:
    def test_director_role_detected(self, setup_db):
        from director_api import _is_director
        from db import get_db
        db = get_db()
        try:
            assert _is_director(db, 1, "director_user") is True
            assert _is_director(db, 1, "host_user") is False
            assert _is_director(db, 1, "guest_user") is False
        finally:
            db.close()


class TestDirectorOnlySound:
    def test_director_only_column(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            db.execute(
                "INSERT INTO sound_effects (session_id, name, filename, director_only) "
                "VALUES (1, 'Stinger', 'stinger.mp3', 1)"
            )
            db.commit()
            row = db.execute("SELECT director_only FROM sound_effects WHERE name='Stinger'").fetchone()
            assert row["director_only"] == 1
        finally:
            db.close()


class TestTriggeredBy:
    def test_triggered_by_column(self, setup_db):
        from db import get_db
        db = get_db()
        try:
            db.execute(
                "INSERT INTO sound_triggers (session_id, sound_filename, tl_offset_seconds, triggered_by) "
                "VALUES (1, 'aplauso.mp3', 12.5, 'director')"
            )
            db.commit()
            row = db.execute("SELECT triggered_by FROM sound_triggers WHERE session_id=1").fetchone()
            assert row["triggered_by"] == "director"
        finally:
            db.close()
