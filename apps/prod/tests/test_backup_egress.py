"""Respaldo grabado por el servidor (LiveKit egress por participante)."""
import os
from types import SimpleNamespace

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
    conn.execute("INSERT INTO sessions (id, title, created_by, livekit_room_name, status) VALUES (1, 'S', 'host', 'room_1', 'recording')")
    conn.execute("INSERT INTO participants (id, session_id, username, display_name, invite_token, role, status) VALUES (10, 1, 'host', 'Host', 'th', 'host', 'connected')")
    conn.execute("INSERT INTO participants (id, session_id, username, display_name, invite_token, role, status) VALUES (11, 1, NULL, 'Invitada', 'tg', 'guest', 'connected')")
    conn.execute("INSERT INTO participants (id, session_id, username, display_name, invite_token, role, status) VALUES (12, 1, 'dir', 'Dir', 'td', 'director', 'connected')")
    conn.commit(); conn.close()

    import recordings_api
    import livekit_service
    started, stopped = [], []
    monkeypatch.setattr(livekit_service, "start_participant_backup",
                        lambda room, ident, path: (started.append((room, ident, path)) or SimpleNamespace(egress_id=f"EG_{ident}")))
    monkeypatch.setattr(livekit_service, "stop_egress", lambda eid: stopped.append(eid))
    monkeypatch.setattr(livekit_service, "egress_status", lambda eid: "EGRESS_COMPLETE")
    state = {"enabled": True}
    monkeypatch.setattr(recordings_api, "backup_enabled", lambda: state["enabled"])
    from app import create_app
    app = create_app(); app.testing = True
    return app.test_client(), recordings_api, db_mod, started, stopped, state


def test_apagado_no_hace_nada(env):
    c, ra, db_mod, started, stopped, state = env
    state["enabled"] = False
    r = c.post("/api/sessions/1/backup/start?token=tg")
    assert r.get_json() == {"enabled": False} and started == []


def test_invitado_pide_su_respaldo_una_sola_vez(env):
    c, ra, db_mod, started, stopped, state = env
    r = c.post("/api/sessions/1/backup/start?token=tg")
    assert r.status_code == 200 and r.get_json()["egress_id"] == "EG_participant_11"
    assert started[0][0] == "room_1" and started[0][1] == "participant_11"
    assert "/sessions/1/backups/p11_respaldo_" in started[0][2]
    r2 = c.post("/api/sessions/1/backup/start?token=tg")
    assert r2.get_json().get("already") is True and len(started) == 1


def test_director_no_se_respalda_y_sin_token_401(env):
    c, ra, db_mod, started, stopped, state = env
    assert c.post("/api/sessions/1/backup/start?token=td").get_json()["skipped"] == "director"
    assert c.post("/api/sessions/1/backup/start").status_code == 401
    assert started == []


def test_detener_cierra_todos_los_respaldos(env):
    c, ra, db_mod, started, stopped, state = env
    c.post("/api/sessions/1/backup/start?token=th")
    c.post("/api/sessions/1/backup/start?token=tg")
    assert ra.stop_session_backups(1) == 2
    assert sorted(stopped) == ["EG_participant_10", "EG_participant_11"]
    assert ra.stop_session_backups(1) == 0   # idempotente


def test_respaldo_reemplaza_solo_a_quien_le_falta_la_grabacion(env):
    c, ra, db_mod, started, stopped, state = env
    c.post("/api/sessions/1/backup/start?token=th")
    c.post("/api/sessions/1/backup/start?token=tg")
    ra.stop_session_backups(1)
    for _, _, path in started:                      # el egress "escribió" los MP4
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(b"\x00" * 1000)
    conn = db_mod.get_db()                           # el host sí subió su grabación
    conn.execute("INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, size_bytes) "
                 "VALUES (1, 10, 'video', 'host.webm', '/x', 10)")
    conn.commit(); conn.close()
    assert ra.adopt_backups(1) == 1                  # solo la invitada
    conn = db_mod.get_db()
    rows = conn.execute("SELECT participant_id, take_id, mime_type FROM recordings ORDER BY id").fetchall()
    conn.close()
    assert [(r["participant_id"], (r["take_id"] or "")[:8]) for r in rows] == [(10, ""), (11, "respaldo")]
    assert ra.adopt_backups(1) == 0                  # no la adopta dos veces
