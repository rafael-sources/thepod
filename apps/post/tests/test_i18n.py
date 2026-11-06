"""Interface language: the English dictionary is well formed (the * in each pattern match), the page declares
the language from the cookie or the browser, and the language script is served."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def test_dictionary_is_sane():
    d = json.load(open(ROOT / "static/i18n/en.json", encoding="utf-8"))
    assert len(d) > 200
    for k, v in d.items():
        assert isinstance(v, str) and v.strip(), k
        assert k.count("*") == v.count("*"), f"the * do not match in {k!r} → {v!r}"


@pytest.fixture
def client(tmp_path, monkeypatch):
    import config, db
    monkeypatch.setattr(config, "PROJECTS_DIR", tmp_path)
    monkeypatch.setattr(db, "PROJECTS_DIR", tmp_path)
    import app as app_module
    monkeypatch.setattr(app_module, "PROJECTS_DIR", tmp_path)
    a = app_module.create_app()
    a.config["TESTING"] = True
    return a.test_client()


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
