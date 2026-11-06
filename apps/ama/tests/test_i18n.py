"""Interface language: English dictionary well formed (the * match), the page declares the language from the
cookie or the browser, and the language script and the dictionary are served."""
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
        assert k.count("*") == v.count("*"), f"the * do not match in {k!r} → {v!r}"


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
