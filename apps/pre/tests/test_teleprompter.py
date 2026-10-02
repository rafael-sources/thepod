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
