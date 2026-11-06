"""Borrar una sala también borra sus archivos en disco."""


def test_borrar_sala_borra_sus_archivos(tmp_path, monkeypatch):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.SESSIONS_DIR = tmp_path / "sessions"
    config.SESSIONS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    db_mod.SESSIONS_DIR = config.SESSIONS_DIR
    conn = db_mod.get_db()
    conn.execute("INSERT INTO sessions (id, title, created_by, livekit_room_name) VALUES (7, 'S', 'host', 'room_7')")
    conn.commit(); conn.close()
    rec = db_mod.session_dir(7) / "recordings"
    rec.mkdir(parents=True, exist_ok=True)
    (rec / "p1_video_x.webm").write_bytes(b"x" * 100)
    import sessions_api
    monkeypatch.setattr(sessions_api, "delete_room", lambda name: None)
    from app import create_app
    app = create_app(); app.testing = True
    c = app.test_client()
    with c.session_transaction() as s:
        s["username"] = "host"
    r = c.delete("/api/sessions/7", base_url="http://castmedia.space")
    assert r.status_code == 200, r.get_json()
    assert not (config.SESSIONS_DIR / "7").exists()   # session_dir() la recrearía
