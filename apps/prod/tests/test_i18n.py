"""Idioma de la interfaz: diccionario inglés bien formado (los * coinciden), la página declara el idioma según la
cookie o el navegador, y el script del idioma y el diccionario se sirven."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def test_dictionary_is_sane():
    d = json.load(open(ROOT / "static/i18n/en.json", encoding="utf-8"))
    assert len(d) > 50
    for k, v in d.items():
        assert isinstance(v, str) and v.strip(), k
        assert k.count("*") == v.count("*"), f"los * no coinciden en {k!r} → {v!r}"


def test_lang_from_cookie_and_browser(client):
    assert b'<html lang="es">' in client.get("/", headers={"Accept-Language": "es-EC"}).data
    assert b'<html lang="en">' in client.get("/", headers={"Accept-Language": "en-US,en;q=0.9"}).data
    client.set_cookie("pod_lang", "en")
    assert b'<html lang="en">' in client.get("/", headers={"Accept-Language": "es-EC"}).data
    client.set_cookie("pod_lang", "es")
    assert b'<html lang="es">' in client.get("/", headers={"Accept-Language": "en-US"}).data
    assert b"pod-i18n.js" in client.get("/").data
    assert client.get("/static/i18n/en.json").status_code == 200
    assert client.get("/static/js/pod-i18n.js").status_code == 200


import pytest


@pytest.fixture
def client(tmp_path):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.SESSIONS_DIR = tmp_path / "sessions"
    config.SESSIONS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    db_mod.SESSIONS_DIR = config.SESSIONS_DIR
    from app import create_app
    app = create_app(); app.testing = True
    app.config["SESSION_COOKIE_DOMAIN"] = None
    return app.test_client()
