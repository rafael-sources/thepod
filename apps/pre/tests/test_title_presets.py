"""Studio · Video title presets (thePod for Mac): they live in the podcast as `title_presets`,
like the voice chains, so they travel to any Mac with the account."""
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
    # they can be emptied
    assert client.put(f"/api/podcasts/{slug}", json={"title_presets": "[]"}).get_json()["title_presets"] == "[]"
