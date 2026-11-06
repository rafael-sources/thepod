"""Prueba aislada del envío automático (base temporal, sin red)."""
import os
import time

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
    conn.execute("INSERT INTO sessions (id, title, created_by, livekit_room_name, status) VALUES (1, 'S', 'host', 'r1', 'recording')")
    conn.execute("INSERT INTO participants (id, session_id, username, display_name, invite_token, role, status) VALUES (10, 1, 'host', 'Host', 'th', 'host', 'connected')")
    conn.execute("INSERT INTO participants (id, session_id, username, display_name, invite_token, role, status) VALUES (11, 1, NULL, 'Invitada', 'tg', 'guest', 'connected')")
    conn.commit(); conn.close()
    import recordings_api
    calls = []
    monkeypatch.setattr(recordings_api, "export_session_to_postpod",
                        lambda sid: (calls.append(sid) or ({"exported": 1, "failed": 0}, 200)))
    rec_dir = db_mod.session_dir(1) / "recordings"
    rec_dir.mkdir(parents=True, exist_ok=True)
    return recordings_api, db_mod, rec_dir, calls


def _add_recording(db_mod, pid, exported=None):
    c = db_mod.get_db()
    c.execute("INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, size_bytes, exported_to_postpod_at) "
              "VALUES (1, ?, 'video', 'f.webm', '/x', 10, ?)", (pid, exported))
    c.commit(); c.close()


def _set_status(db_mod, st):
    c = db_mod.get_db(); c.execute("UPDATE sessions SET status=? WHERE id=1", (st,)); c.commit(); c.close()


def _wait(calls, n=1):
    for _ in range(50):
        if len(calls) >= n:
            return
        time.sleep(0.02)


def test_no_envia_si_la_sala_sigue_grabando(env):
    ra, db_mod, rec_dir, calls = env
    _add_recording(db_mod, 10)
    assert ra.maybe_auto_export(1) is False and calls == []


def test_no_envia_si_alguien_sigue_subiendo(env):
    ra, db_mod, rec_dir, calls = env
    _set_status(db_mod, "finished")
    _add_recording(db_mod, 10)
    (rec_dir / "p11_video_streaming_tX.webm").write_bytes(b"x")   # subida activa
    assert ra.maybe_auto_export(1) is False and calls == []


def test_envia_cuando_termina_la_ultima(env):
    ra, db_mod, rec_dir, calls = env
    _set_status(db_mod, "finished")
    _add_recording(db_mod, 10)
    _add_recording(db_mod, 11)
    assert ra.maybe_auto_export(1) is True
    _wait(calls)
    assert calls == [1]


def test_subida_abandonada_no_bloquea(env):
    ra, db_mod, rec_dir, calls = env
    _set_status(db_mod, "finished")
    _add_recording(db_mod, 10)
    f = rec_dir / "p11_video_streaming_tX.webm"
    f.write_bytes(b"x")
    viejo = time.time() - 25 * 60
    os.utime(f, (viejo, viejo))   # sin escribir hace 25 min
    assert ra.maybe_auto_export(1) is True
    _wait(calls)
    assert calls == [1]


def test_no_reenvia_lo_ya_enviado(env):
    ra, db_mod, rec_dir, calls = env
    _set_status(db_mod, "finished")
    _add_recording(db_mod, 10, exported="2026-10-04T15:00:00+00:00")
    assert ra.maybe_auto_export(1) is False and calls == []
