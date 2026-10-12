"""Tests de pubpod.py — conectar redes, crear/programar reels y publicarlos."""

import sys
import time
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from flask import Flask

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config
import db as db_mod
import mac_publish
import pubpod

SLUG = "mi-podcast"
CFG = {"prepod_url": "https://prepod.example", "instagram": {"app_id": "1", "app_secret": "s"}}


@pytest.fixture
def client(tmp_path, monkeypatch):
    podcasts_dir = tmp_path / "podcasts"
    podcasts_dir.mkdir()
    for mod in (config, db_mod, mac_publish, pubpod):
        monkeypatch.setattr(mod, "PODCASTS_DIR", podcasts_dir)
    monkeypatch.setattr(pubpod, "load_shared_config", lambda: CFG)
    monkeypatch.setattr(pubpod.time, "sleep", lambda s: None)
    db_mod.get_db(SLUG).close()

    app = Flask(__name__)
    app.secret_key = "test"
    app.register_blueprint(mac_publish.bp)
    app.register_blueprint(pubpod.bp)
    with app.test_client() as c:
        with c.session_transaction() as s:
            s["username"] = "tester"
        yield c


def _upload(client, data=b"fakevideo"):
    r = client.post("/api/mac/uploads", json={"filename": "reel.mp4", "size": len(data)})
    uid = r.get_json()["upload_id"]
    client.put(f"/api/mac/uploads/{uid}/chunk?index=0", data=data)
    assert client.post(f"/api/mac/uploads/{uid}/finish").status_code == 200
    return uid


def _connect_ig():
    pubpod._save_account(SLUG, "instagram", "17841", "mipodcast", "TOK",
                         time.time() + 50 * 86400, "tester")


def _reel(client, **kw):
    body = {"slug": SLUG, "upload_id": _upload(client), "title": "Momento 1",
            "targets": [{"platform": "instagram", "caption": "Hola #podcast"}]}
    body.update(kw)
    return client.post("/api/pubpod/reels", json=body)


def _resp(status=200, json_data=None):
    m = MagicMock()
    m.ok = status < 400
    m.status_code = status
    m.json.return_value = json_data or {}
    m.text = str(json_data)
    return m


def test_requires_auth(client):
    with client.session_transaction() as s:
        s.clear()
    assert client.get(f"/api/pubpod/podcasts/{SLUG}/posts").status_code == 401


def test_needs_connected_network(client):
    r = _reel(client)
    assert r.status_code == 400
    assert "Instagram" in r.get_json()["error"]


def test_upload_released_when_validation_fails(client):
    uid = _upload(client)
    body = {"slug": SLUG, "upload_id": uid, "title": "x", "targets": []}
    assert client.post("/api/pubpod/reels", json=body).status_code == 400
    _connect_ig()
    body["targets"] = [{"platform": "instagram", "caption": ""}]
    assert client.post("/api/pubpod/reels", json=body).status_code == 201


def test_rejects_unknown_network_and_past_date(client):
    _connect_ig()
    r = _reel(client, targets=[{"platform": "myspace"}])
    assert r.status_code == 400
    r = _reel(client, scheduled_at="2020-01-01T10:00:00Z")
    assert "pasó" in r.get_json()["error"]
    r = _reel(client, scheduled_at="2030-01-01T10:00:00")
    assert "zona" in r.get_json()["error"]


def test_other_users_podcast_denied(client):
    conn = db_mod.get_db(SLUG)
    conn.execute("INSERT INTO podcast_meta (name, slug, owner_username) VALUES ('P', ?, 'otro')", (SLUG,))
    conn.commit()
    conn.close()
    assert client.get(f"/api/pubpod/podcasts/{SLUG}/posts").status_code == 403


def test_publish_instagram_reel(client, monkeypatch):
    _connect_ig()
    r = _reel(client)
    assert r.status_code == 201
    post = r.get_json()["posts"][0]
    assert post["status"] == "scheduled"

    token = pubpod._db(SLUG).execute("SELECT media_token FROM pub_posts").fetchone()[0]
    # El video está disponible públicamente mientras la publicación está pendiente
    assert client.get(f"/pub/m/{SLUG}/{token}.mp4").status_code == 200

    calls = []

    def fake_post(url, data=None, timeout=None):
        calls.append(("POST", url, data))
        if url.endswith("/17841/media"):
            assert data["media_type"] == "REELS"
            assert data["video_url"] == f"https://prepod.example/pub/m/{SLUG}/{token}.mp4"
            return _resp(200, {"id": "C1"})
        if url.endswith("/media_publish"):
            return _resp(200, {"id": "M1"})
        raise AssertionError(url)

    states = iter(["IN_PROGRESS", "FINISHED"])

    def fake_get(url, params=None, timeout=None):
        if url.endswith("/C1"):
            return _resp(200, {"status_code": next(states)})
        if url.endswith("/M1"):
            return _resp(200, {"permalink": "https://www.instagram.com/reel/abc/"})
        raise AssertionError(url)

    monkeypatch.setattr(pubpod.requests, "post", fake_post)
    monkeypatch.setattr(pubpod.requests, "get", fake_get)

    assert pubpod.run_due(SLUG) == 1
    posts = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"]
    assert posts[0]["status"] == "published"
    assert posts[0]["result_url"] == "https://www.instagram.com/reel/abc/"
    # Ya publicado: el video deja de ser público y se borra
    assert client.get(f"/pub/m/{SLUG}/{token}.mp4").status_code == 404
    assert not pubpod._media_path(SLUG, token).exists()


def test_instagram_error_then_retry(client, monkeypatch):
    _connect_ig()
    _reel(client)
    monkeypatch.setattr(pubpod.requests, "post", lambda *a, **k: _resp(400, {
        "error": {"message": "x", "error_user_msg": "La cuenta no es profesional"}}))
    pubpod.run_due(SLUG)
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "error"
    assert "profesional" in post["error"]
    r = client.post(f"/api/pubpod/podcasts/{SLUG}/posts/{post['id']}/retry")
    assert r.status_code == 200
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "scheduled"


def test_future_post_waits_and_can_be_cancelled(client):
    _connect_ig()
    r = _reel(client, scheduled_at="2099-05-01T15:00:00-05:00")
    post = r.get_json()["posts"][0]
    assert pubpod.run_due(SLUG) == 0
    assert client.post(f"/api/pubpod/podcasts/{SLUG}/posts/{post['id']}/cancel").status_code == 200
    assert client.post(f"/api/pubpod/podcasts/{SLUG}/posts/{post['id']}/cancel").status_code == 409
    assert not list((pubpod.PODCASTS_DIR / SLUG / "pubpod").glob("*.mp4"))


def test_youtube_short(client, monkeypatch):
    import youtube_publish
    monkeypatch.setattr(youtube_publish, "_get_stored_tokens", lambda slug: {"access_token": "a"})
    seen = {}

    def fake_upload(slug, path, title, desc, privacy, category):
        seen["title"] = title
        return {"ok": True, "video_id": "VID", "url": "https://www.youtube.com/watch?v=VID"}

    monkeypatch.setattr(youtube_publish, "_upload_video", fake_upload)
    r = _reel(client, targets=[{"platform": "youtube", "caption": "desc"}])
    assert r.status_code == 201
    pubpod.run_due(SLUG)
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert seen["title"].endswith("#Shorts")
    assert post["result_url"] == "https://youtube.com/shorts/VID"
    assert post["status"] in ("published", "private")


def test_callback_rejects_bad_state(client):
    r = client.get("/api/pubpod/instagram/callback?code=x&state=forged")
    assert r.status_code == 400


def test_auth_url_signed_state(client):
    r = client.get(f"/api/pubpod/instagram/auth-url?slug={SLUG}")
    url = r.get_json()["auth_url"]
    assert "instagram_business_content_publish" in url
    assert "redirect_uri=https%3A%2F%2Fprepod.example%2Fapi%2Fpubpod%2Finstagram%2Fcallback" in url


def test_interrupted_posts_become_errors(client):
    _connect_ig()
    _reel(client)
    conn = pubpod._db(SLUG)
    conn.execute("UPDATE pub_posts SET status='publishing'")
    conn.commit()
    conn.close()
    pubpod._recover_interrupted()
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "error"
