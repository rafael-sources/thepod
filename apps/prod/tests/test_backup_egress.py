"""Server-recorded backup (LiveKit egress per participant)."""
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
    assert ra.stop_session_backups(1) == 0   # idempotent


def test_respaldo_reemplaza_solo_a_quien_le_falta_la_grabacion(env):
    c, ra, db_mod, started, stopped, state = env
    c.post("/api/sessions/1/backup/start?token=th")
    c.post("/api/sessions/1/backup/start?token=tg")
    ra.stop_session_backups(1)
    for _, _, path in started:                      # the egress "wrote" the MP4s
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(b"\x00" * 1000)
    conn = db_mod.get_db()                           # the host did upload their recording
    conn.execute("INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, size_bytes) "
                 "VALUES (1, 10, 'video', 'host.webm', '/x', 10)")
    conn.commit(); conn.close()
    assert ra.adopt_backups(1) == 1                  # only the guest
    conn = db_mod.get_db()
    rows = conn.execute("SELECT participant_id, take_id, mime_type FROM recordings ORDER BY id").fetchall()
    conn.close()
    assert [(r["participant_id"], (r["take_id"] or "")[:8]) for r in rows] == [(10, ""), (11, "respaldo")]
    assert ra.adopt_backups(1) == 0                  # does not adopt it twice


def test_envio_avisa_inicio_y_fin_y_manda_el_respaldo(env, monkeypatch):
    c, ra, db_mod, started, stopped, state = env
    c.post("/api/sessions/1/backup/start?token=tg")
    ra.stop_session_backups(1)
    path = started[0][2]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"\x00" * 1000)
    calls = []

    class _Resp:
        status_code = 201
        text = ""
        def json(self):
            return {"project": {"slug": "p"}}

    def fake_post(url, **kw):
        files = kw.get("files") or {}
        calls.append((url.rsplit("/", 1)[-1], (kw.get("json") or {}).get("state"),
                      files["file"][0] if "file" in files else None))
        return _Resp()
    monkeypatch.setattr(ra.requests, "post", fake_post)
    monkeypatch.setattr(ra, "notify_source", lambda *a, **k: None)
    body, status = ra.export_session_to_postpod(1)
    assert body["exported"] == 1 and body["failed"] == 0, body
    tipos = [x[0] for x in calls]
    assert tipos[0] == "import-status" and calls[0][1] == "begin"
    assert "import-track" in tipos
    assert ("import-status", "end", None) in calls
    assert tipos.index("import-track") < tipos.index("import-status", 1)


def test_envio_interno_y_pista_fija_por_persona(env, monkeypatch):
    """A track sent late does not land on someone else's, and the send goes
    to postPod's internal address (not the public proxy)."""
    c, ra, db_mod, started, stopped, state = env
    rec = db_mod.session_dir(1) / "recordings"
    rec.mkdir(parents=True, exist_ok=True)
    conn = db_mod.get_db()
    for pid in (10, 11):
        f = rec / f"p{pid}.webm"
        f.write_bytes(b"x" * 10)
        conn.execute("INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, size_bytes, exported_to_postpod_at) "
                     "VALUES (1, ?, 'video', ?, ?, 10, ?)", (pid, f.name, str(f), "2026-10-12T00:00:00" if pid == 10 else None))
    conn.commit(); conn.close()
    sent = []

    class _Resp:
        status_code = 201
        text = ""
        def json(self):
            return {"project": {"slug": "p"}}

    def fake_post(url, **kw):
        if url.endswith("/import-track"):
            sent.append((url, kw["data"]["track_number"], kw["data"]["original_name"]))
        return _Resp()
    monkeypatch.setattr(ra.requests, "post", fake_post)
    monkeypatch.setattr(ra, "notify_source", lambda *a, **k: None)
    body, status = ra.export_session_to_postpod(1)
    assert body["exported"] == 1, body
    url, track, name = sent[0]
    assert url.startswith(ra.POSTPOD_INTERNAL_URL)
    assert name.startswith("Invitada") and track == "2"   # track 1 belongs to the host, even though it was already sent
