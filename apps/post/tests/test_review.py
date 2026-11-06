"""Timestamped review: upload a version, open the link without an account, comment at a given second,
read the comments from the Mac (with a session), resolve and revoke."""
import io
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@pytest.fixture
def app(tmp_path, monkeypatch):
    import config
    import db
    import review
    monkeypatch.setattr(config, "PROJECTS_DIR", tmp_path)
    monkeypatch.setattr(db, "PROJECTS_DIR", tmp_path)
    monkeypatch.setattr(review, "PROJECTS_DIR", tmp_path)
    monkeypatch.setattr(review, "INDEX", tmp_path / "_review_index.json")
    (tmp_path / "ep-1").mkdir()
    import app as app_module
    monkeypatch.setattr(app_module, "PROJECTS_DIR", tmp_path)
    a = app_module.create_app()
    a.config["TESTING"] = True
    return a


def _login(client):
    with client.session_transaction() as s:
        s["username"] = "admin"


def test_review_flow(app):
    c = app.test_client()
    # without a session uploading is not allowed
    r = c.post("/api/projects/ep-1/review", data={"file": (io.BytesIO(b"ID3mp3"), "episodio.mp3")})
    assert r.status_code == 401
    _login(c)
    r = c.post("/api/projects/ep-1/review", data={"file": (io.BytesIO(b"ID3mp3"), "episodio.mp3"), "title": "Ep 15"})
    assert r.status_code == 200, r.data
    token = r.get_json()["token"]
    assert r.get_json()["url"].endswith("/r/" + token)
    # the public page opens without a session and serves the file
    anon = app.test_client()
    page = anon.get(f"/r/{token}")
    assert page.status_code == 200 and b"Ep 15" in page.data and b"<audio" in page.data
    media = anon.get(f"/r/{token}/media")
    assert media.status_code == 200 and media.data == b"ID3mp3"
    # comment at a given second
    r = anon.post(f"/r/{token}/comments", json={"t": 83.4, "author": "Caro", "text": "Aquí se corta la frase"})
    assert r.status_code == 201
    r = anon.post(f"/r/{token}/comments", json={"t": 10, "text": "   "})
    assert r.status_code == 400
    # the Mac reads them (with a session), sorted by time
    anon.post(f"/r/{token}/comments", json={"t": 12, "text": "Sube la música"})
    r = c.get(f"/api/projects/ep-1/review/{token}/comments")
    cs = r.get_json()["comments"]
    assert [x["t"] for x in cs] == [12, 83.4] and cs[1]["author"] == "Caro" and not cs[1]["resolved"]
    # resolve
    r = c.post(f"/api/projects/ep-1/review/{token}/comments/{cs[1]['id']}/resolve", json={"resolved": True})
    assert r.status_code == 200
    assert c.get(f"/api/projects/ep-1/review/{token}/comments").get_json()["comments"][1]["resolved"] is True
    # another project cannot read this link
    assert c.get(f"/api/projects/otro/review/{token}/comments").status_code == 404
    # revoke: the link stops opening
    assert c.delete(f"/api/projects/ep-1/review/{token}").status_code == 200
    assert anon.get(f"/r/{token}").status_code == 404
    assert anon.post(f"/r/{token}/comments", json={"t": 1, "text": "x"}).status_code == 404


def test_rejects_wrong_files_and_tokens(app):
    c = app.test_client()
    _login(c)
    r = c.post("/api/projects/ep-1/review", data={"file": (io.BytesIO(b"x"), "cosa.exe")})
    assert r.status_code == 400
    assert c.post("/api/projects/ep-1/review", data={}).status_code == 400
    assert app.test_client().get("/r/no-existe-este-token").status_code == 404
    assert app.test_client().get("/r/abc.def-ghi-jkl-mnop").status_code == 404   # a token with characters outside the alphabet opens nothing
