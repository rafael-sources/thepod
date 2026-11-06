"""Transmisión en vivo: si la plataforma la rechaza o se corta, la sala se entera."""
import pytest


@pytest.fixture
def env(tmp_path, monkeypatch):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.SESSIONS_DIR = tmp_path / "sessions"
    config.SESSIONS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    db_mod.SESSIONS_DIR = config.SESSIONS_DIR
    conn = db_mod.get_db()
    conn.execute("INSERT INTO sessions (id, title, created_by, livekit_room_name, status) VALUES (1, 'S', 'host', 'room_1', 'live')")
    conn.execute("INSERT INTO live_streams (id, session_id, platform, rtmp_url, stream_key, status, started_by, egress_id) "
                 "VALUES (5, 1, 'youtube', 'rtmp://x/', 'k', 'active', 'host', 'EG_1')")
    conn.commit(); conn.close()

    import streams_api
    state = {"info": ("EGRESS_ACTIVE", "", ["ACTIVE"]), "stopped": []}
    monkeypatch.setattr(streams_api, "egress_info", lambda eid: state["info"])
    monkeypatch.setattr(streams_api, "stop_egress", lambda eid: state["stopped"].append(eid))
    from app import create_app
    app = create_app(); app.testing = True
    c = app.test_client()
    with c.session_transaction() as s:
        s["username"] = "host"
    return c, state


def _stream(c):
    r = c.get("/api/sessions/1/streams")
    assert r.status_code == 200
    return r.get_json()[0]


def test_activa_sigue_activa(env):
    c, state = env
    assert _stream(c)["status"] == "active"


def test_destino_rechazado_se_marca_y_se_detiene(env):
    c, state = env
    state["info"] = ("EGRESS_ACTIVE", "", ["FAILED"])
    s = _stream(c)
    assert s["status"] == "failed"
    assert "clave" in s["error"]
    assert state["stopped"] == ["EG_1"]


def test_egress_fallido(env):
    c, state = env
    state["info"] = ("EGRESS_FAILED", "rtmp error", [])
    assert _stream(c)["status"] == "failed"
    assert state["stopped"] == []


def test_terminada_queda_detenida(env):
    c, state = env
    state["info"] = ("EGRESS_COMPLETE", "", ["FINISHED"])
    assert _stream(c)["status"] == "stopped"


def test_sin_respuesta_no_cambia(env):
    c, state = env
    state["info"] = None
    assert _stream(c)["status"] == "active"
