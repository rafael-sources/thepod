"""Teleprompter por sección del guion: columna tp_speaker y endpoint para prodPod."""
import sys
from pathlib import Path

import pytest
from flask import Flask

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config
import db as db_mod
import episodes
import integrations
import podcasts


@pytest.fixture
def client(tmp_path):
    podcasts_dir = tmp_path / "podcasts"
    podcasts_dir.mkdir()
    saved = {m: m.PODCASTS_DIR for m in (config, db_mod, episodes, integrations, podcasts)}
    for m in saved:
        m.PODCASTS_DIR = podcasts_dir
    app = Flask(__name__)
    app.secret_key = "test"
    for m in (episodes, integrations, podcasts):
        app.register_blueprint(m.bp)
    with app.test_client() as c:
        with c.session_transaction() as s:
            s["username"] = "tester"
        yield c
    for m, v in saved.items():
        m.PODCASTS_DIR = v


def test_tp_speaker_roundtrip_and_endpoint(client):
    r = client.post("/api/podcasts", json={"name": "Demo Pod"})
    assert r.status_code in (200, 201), r.data
    slug = r.get_json()["slug"]
    r = client.post(f"/api/podcasts/{slug}/episodes", json={"title": "Ep 1"})
    assert r.status_code in (200, 201), r.data
    ep = r.get_json()["id"]
    r = client.post(f"/api/podcasts/{slug}/episodes/{ep}/script", json={"speaker": "Patricio", "content": "Hola"})
    sec = r.get_json()
    r = client.put(f"/api/podcasts/{slug}/script-sections/{sec['id']}",
                     json={"tp_enabled": True, "tp_offset_seconds": 5, "tp_speaker": "patricio", "tp_size": "full"})
    assert r.status_code == 200, r.data
    d = r.get_json()
    assert d["tp_speaker"] == "patricio" and d["tp_offset_seconds"] == 5 and d["tp_size"] == "full"

    r = client.get(f"/api/integrations/teleprompter?slug={slug}&episode_id={ep}",
                   headers={"X-PodPod-Secret": config.INTEGRATION_SECRET})
    assert r.status_code == 200, r.data
    s = r.get_json()["sections"]
    assert len(s) == 1
    assert s[0]["speaker"] == "Patricio" and s[0]["speaker_key"] == "patricio" and s[0]["offset_seconds"] == 5


def test_chained_offsets(client):
    r = client.post("/api/podcasts", json={"name": "Cadena"})
    slug = r.get_json()["slug"]
    ep = client.post(f"/api/podcasts/{slug}/episodes", json={"title": "Ep"}).get_json()["id"]
    a = client.post(f"/api/podcasts/{slug}/episodes/{ep}/script", json={"speaker": "Patricio", "content": " ".join(["palabra"] * 27)}).get_json()
    b = client.post(f"/api/podcasts/{slug}/episodes/{ep}/script", json={"speaker": "Karelia", "content": "corto"}).get_json()
    client.put(f"/api/podcasts/{slug}/script-sections/{a['id']}", json={"tp_enabled": True, "tp_offset_seconds": 5, "tp_speaker": "patricio"})
    client.put(f"/api/podcasts/{slug}/script-sections/{b['id']}", json={"tp_enabled": True, "tp_after_prev": True, "tp_gap_seconds": 0.5, "tp_speaker": "Karelia"})
    s = client.get(f"/api/integrations/teleprompter?slug={slug}&episode_id={ep}",
                   headers={"X-PodPod-Secret": config.INTEGRATION_SECRET}).get_json()["sections"]
    # 27 palabras a 135 wpm = 12 s + 2,5 = 14,5 s → termina en 19,5; el siguiente a 0,5 s → 20,0
    assert s[0]["offset_seconds"] == 5 and s[0]["ends_seconds"] == 19.5
    assert s[1]["after_prev"] is True and s[1]["offset_seconds"] == 20.0 and s[1]["gap_seconds"] == 0.5
