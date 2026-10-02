"""Teleprompter (thePod 0.11): el proxy a prePod y el acceso por token de invitado."""

import io
import json
import urllib.request

import pytest


@pytest.fixture
def tp_db(tmp_path):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.SESSIONS_DIR = tmp_path / "sessions"
    config.SESSIONS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    db_mod.SESSIONS_DIR = config.SESSIONS_DIR
    conn = db_mod.get_db()
    conn.execute(
        "INSERT INTO sessions (id, title, created_by, shared_project_id, livekit_room_name, source_url, source_slug, source_episode_id, sponsors_json) "
        "VALUES (1, 'S', 'host_user', 'p', 'room_1', 'http://prepod.test', 'demo', 14, '[{\"name\": \"Respaldo\"}]')"
    )
    conn.execute("INSERT INTO participants (session_id, username, display_name, invite_token, role, status) VALUES (1, 'host_user', 'Patricio', 'tok-host', 'host', 'connected')")
    conn.execute("INSERT INTO participants (session_id, username, display_name, invite_token, role, status) VALUES (1, 'guest', 'Karelia', 'tok-guest', 'guest', 'connected')")
    conn.commit()
    conn.close()
    from app import create_app
    app = create_app()
    app.testing = True
    return app


class _Resp(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False


def test_proxy_to_prepod(tp_db, monkeypatch):
    seen = {}
    def fake_open(req, timeout=0):
        seen["url"] = req.full_url
        seen["secret"] = req.headers.get("X-podpod-secret")
        return _Resp(json.dumps({"sections": [{"id": 1, "speaker": "Patricio", "content": "Hola", "offset_seconds": 12, "speed": "fast", "size": "full"}],
                                 "sponsors": [{"name": "Loma Verde", "copy": "Café"}]}).encode())
    monkeypatch.setattr(urllib.request, "urlopen", fake_open)
    c = tp_db.test_client()
    with c.session_transaction() as s:
        s["username"] = "host_user"
    r = c.get("/api/sessions/1/teleprompter")
    assert r.status_code == 200
    d = r.get_json()
    assert "slug=demo&episode_id=14" in seen["url"] and seen["secret"]
    assert d["sections"][0]["speaker"] == "Patricio" and d["sections"][0]["size"] == "full"
    assert d["sponsors"][0]["name"] == "Loma Verde"
    idents = {p["display_name"]: p["identity"] for p in d["participants"]}
    assert idents["Karelia"].startswith("participant_")


def test_guest_token_and_fallback_sponsors(tp_db, monkeypatch):
    def boom(req, timeout=0):
        raise OSError("prePod apagado")
    monkeypatch.setattr(urllib.request, "urlopen", boom)
    c = tp_db.test_client()
    assert c.get("/api/sessions/1/teleprompter").status_code == 401
    r = c.get("/api/sessions/1/teleprompter?token=tok-guest")
    assert r.status_code == 200
    d = r.get_json()
    assert d["sections"] == [] and d["sponsors"][0]["name"] == "Respaldo"


def test_director_can_log_teleprompter(tp_db):
    c = tp_db.test_client()
    import db as db_mod
    conn = db_mod.get_db()
    conn.execute("INSERT INTO participants (session_id, username, display_name, invite_token, role, status) VALUES (1, 'dir', 'Dir', 'tok-dir', 'director', 'connected')")
    conn.commit(); conn.close()
    with c.session_transaction() as s:
        s["username"] = "dir"
    r = c.post("/api/sessions/1/director/inject", json={"event_type": "teleprompter", "payload": {"target": "all", "text": "Hola"}})
    assert r.status_code == 201, r.get_json()
