import sqlite3
import pytest

@pytest.fixture
def test_db(tmp_path):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.EVENTS_DIR = tmp_path / "events"
    config.EVENTS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    conn = db_mod.get_db()
    yield conn
    conn.close()

def test_schema_creates_tables(test_db):
    tables = [r[0] for r in test_db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).fetchall()]
    assert "events" in tables
    assert "participants" in tables
    assert "chat_messages" in tables
    assert "event_templates" in tables

def test_wal_mode(test_db):
    mode = test_db.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode == "wal"

def test_foreign_keys_on(test_db):
    fk = test_db.execute("PRAGMA foreign_keys").fetchone()[0]
    assert fk == 1

def test_event_status_check(test_db):
    test_db.execute(
        "INSERT INTO events (title, host_username, status) VALUES ('Test', 'admin', 'created')"
    )
    test_db.commit()
    with pytest.raises(sqlite3.IntegrityError):
        test_db.execute(
            "INSERT INTO events (title, host_username, status) VALUES ('Bad', 'admin', 'invalid')"
        )

def test_participant_unique_per_event(test_db):
    test_db.execute(
        "INSERT INTO events (id, title, host_username) VALUES (1, 'Test', 'admin')"
    )
    test_db.execute(
        "INSERT INTO participants (event_id, display_name, access_token) VALUES (1, 'Ana', 'tok1')"
    )
    test_db.commit()
    with pytest.raises(sqlite3.IntegrityError):
        test_db.execute(
            "INSERT INTO participants (event_id, display_name, access_token) VALUES (1, 'Ana', 'tok2')"
        )

def test_event_dir_created(tmp_path):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.EVENTS_DIR = tmp_path / "events"
    config.EVENTS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    path = db_mod.event_dir(42)
    assert path.exists()
    assert (path / "recordings").exists()
    assert (path / "chat").exists()
