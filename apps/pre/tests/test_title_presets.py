"""Plantillas de título de Studio · Video (thePod para Mac): viven en el podcast como `title_presets`,
igual que las cadenas de voz, para que viajen a cualquier Mac con la cuenta."""
import json
import sys
from pathlib import Path

import pytest
from flask import Flask

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config
import db as db_mod
import podcasts


@pytest.fixture
def client(tmp_path, monkeypatch):
    podcasts_dir = tmp_path / "podcasts"
    podcasts_dir.mkdir()
    for mod in (config, db_mod, podcasts):
        monkeypatch.setattr(mod, "PODCASTS_DIR", podcasts_dir)
    monkeypatch.setattr(podcasts, "policy_for", lambda u: {})
    app = Flask(__name__)
    app.secret_key = "test"
    app.register_blueprint(podcasts.bp)
    with app.test_client() as c:
        with c.session_transaction() as s:
            s["username"] = "tester"
        yield c


def test_title_presets_round_trip(client):
    slug = client.post("/api/podcasts", json={"name": "Mi podcast"}).get_json()["slug"]
    assert client.get(f"/api/podcasts/{slug}").get_json()["title_presets"] is None
    presets = json.dumps([{"id": "A", "name": "Nombre abajo", "style": "box", "color": "#FFFFFF", "x": 0.5, "y": 0.85, "scale": 1.0,
                           "enter": {"kind": "rise", "duration": 0.4}, "duration": 5}])
    r = client.put(f"/api/podcasts/{slug}", json={"title_presets": presets})
    assert r.status_code == 200, r.data
    assert r.get_json()["title_presets"] == presets
    assert client.get(f"/api/podcasts/{slug}").get_json()["title_presets"] == presets
    # se pueden vaciar
    assert client.put(f"/api/podcasts/{slug}", json={"title_presets": "[]"}).get_json()["title_presets"] == "[]"
