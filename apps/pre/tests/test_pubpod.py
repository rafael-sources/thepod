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
CFG = {"prepod_url": "https://prepod.example", "instagram": {"app_id": "1", "app_secret": "s"},
       "tiktok": {"client_key": "ck", "client_secret": "cs"}}


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
    step = 16 * 1024 * 1024
    for i in range(0, max(1, len(data)), step):
        client.put(f"/api/mac/uploads/{uid}/chunk?index={i // step}", data=data[i:i + step])
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


def _connect_tt(expires_in=86400):
    pubpod._tt_save_tokens(SLUG, {"open_id": "OID", "access_token": "TT", "refresh_token": "RT",
                                  "expires_in": expires_in, "refresh_expires_in": 31536000},
                           "tester", "Mi Podcast")


def test_tiktok_needs_connection_then_shows_account(client):
    r = _reel(client, targets=[{"platform": "tiktok", "caption": "hola"}])
    assert "TikTok" in r.get_json()["error"]
    _connect_tt()
    acc = client.get(f"/api/pubpod/podcasts/{SLUG}/accounts").get_json()
    assert acc["tiktok"] == {"connected": True, "username": "Mi Podcast"}
    assert client.get("/api/pubpod/networks").get_json()["tiktok"] is True


def test_tiktok_sends_to_inbox_in_chunks(client, monkeypatch):
    _connect_tt()
    big = b"x" * (70 * 1024 * 1024 + 123)          # > 64 MB → trozos de 10 MB, el último con el resto
    uid = _upload(client, big)
    r = client.post("/api/pubpod/reels", json={"slug": SLUG, "upload_id": uid, "title": "T",
                                                "targets": [{"platform": "tiktok", "caption": "c"}]})
    assert r.status_code == 201
    puts, posts = [], []

    def fake_post(url, headers=None, json=None, data=None, timeout=None):
        posts.append(url)
        if url.endswith("/inbox/video/init/"):
            si = json["source_info"]
            assert si["source"] == "FILE_UPLOAD" and si["video_size"] == len(big)
            assert si["chunk_size"] == 10 * 1024 * 1024 and si["total_chunk_count"] == 7
            assert headers["Authorization"] == "Bearer TT"
            return _resp(200, {"data": {"publish_id": "P1", "upload_url": "https://up.tiktok/x"}})
        if url.endswith("/status/fetch/"):
            return _resp(200, {"data": {"status": "SEND_TO_USER_INBOX"}})
        raise AssertionError(url)

    def fake_put(url, data=None, headers=None, timeout=None):
        puts.append((headers["Content-Range"], len(data)))
        return _resp(206 if len(puts) < 7 else 201)

    monkeypatch.setattr(pubpod.requests, "post", fake_post)
    monkeypatch.setattr(pubpod.requests, "put", fake_put)
    pubpod.run_due(SLUG)
    assert len(puts) == 7
    assert puts[0][0] == f"bytes 0-{10*1024*1024-1}/{len(big)}"
    assert puts[-1][0].endswith(f"-{len(big)-1}/{len(big)}")
    assert sum(n for _, n in puts) == len(big)
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "inbox"


def test_tiktok_pending_limit_message(client, monkeypatch):
    _connect_tt()
    _reel(client, targets=[{"platform": "tiktok", "caption": ""}])
    monkeypatch.setattr(pubpod.requests, "post", lambda *a, **k: _resp(403, {
        "error": {"code": "spam_risk_too_many_pending_share", "message": "x"}}))
    pubpod.run_due(SLUG)
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "error" and "5 videos" in post["error"]


def test_tiktok_token_refresh(client, monkeypatch):
    _connect_tt(expires_in=60)                     # vence en 1 minuto → se renueva
    calls = []

    def fake_post(url, data=None, timeout=None, **k):
        calls.append(data)
        return _resp(200, {"access_token": "NEW", "refresh_token": "RT2", "expires_in": 86400,
                           "refresh_expires_in": 31536000})

    monkeypatch.setattr(pubpod.requests, "post", fake_post)
    assert pubpod._tt_token(SLUG) == "NEW"
    assert calls[0]["grant_type"] == "refresh_token" and calls[0]["refresh_token"] == "RT"
    assert pubpod._get_account(SLUG, "tiktok")["refresh_token"] == "RT2"


def test_tiktok_state_cannot_be_used_for_instagram(client):
    st = pubpod._state.dumps({"slug": SLUG, "user": "tester", "net": "tiktok"})
    assert client.get(f"/api/pubpod/instagram/callback?code=x&state={st}").status_code == 400


def test_migration_from_first_version(client):
    """Una base creada con la primera versión (sin 'inbox' ni refresh) se actualiza sin perder nada."""
    import sqlite3
    conn = db_mod.get_db(SLUG)
    old = pubpod.SCHEMA.replace("'private','inbox','error'", "'private','error'")
    conn.executescript(old)
    conn.execute("INSERT INTO pub_posts (title, platform, media_token, scheduled_at) VALUES ('viejo','instagram','t',1)")
    conn.commit()
    conn.close()
    conn = pubpod._db(SLUG)
    sql = conn.execute("SELECT sql FROM sqlite_master WHERE name='pub_posts'").fetchone()[0]
    assert "'inbox'" in sql
    assert conn.execute("SELECT title FROM pub_posts").fetchone()[0] == "viejo"
    assert conn.execute("SELECT name FROM sqlite_master WHERE name='idx_pub_posts_due'").fetchone()
    conn.close()


def _signed(payload, secret="s"):
    import base64, hashlib, hmac, json as _j
    enc = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
    body = enc(_j.dumps(payload).encode())
    sig = enc(hmac.new(secret.encode(), body.encode(), hashlib.sha256).digest())
    return f"{sig}.{body}"


def test_meta_data_deletion_removes_connection(client):
    _connect_ig()
    _reel(client, scheduled_at="2099-01-01T00:00:00Z")
    r = client.post("/api/pubpod/instagram/data-deletion",
                    data={"signed_request": _signed({"user_id": "17841", "algorithm": "HMAC-SHA256"})})
    out = r.get_json()
    assert r.status_code == 200 and out["confirmation_code"] and "/pub/borrado?codigo=" in out["url"]
    assert pubpod._get_account(SLUG, "instagram") is None
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "cancelled"
    assert client.get(out["url"].split("prepod.example")[1]).status_code == 200


def test_meta_deauthorize_rejects_forged_signature(client):
    _connect_ig()
    r = client.post("/api/pubpod/instagram/deauthorize",
                    data={"signed_request": _signed({"user_id": "17841"}, secret="otra")})
    assert r.status_code == 400
    assert pubpod._get_account(SLUG, "instagram") is not None
    r = client.post("/api/pubpod/instagram/deauthorize",
                    data={"signed_request": _signed({"user_id": "17841"})})
    assert r.status_code == 200 and pubpod._get_account(SLUG, "instagram") is None


def test_full_episode_to_youtube_without_shorts_tag(client, monkeypatch):
    import youtube_publish
    monkeypatch.setattr(youtube_publish, "_get_stored_tokens", lambda slug: {"access_token": "a"})
    seen = {}

    def fake_upload(slug, path, title, desc, privacy, category):
        seen["title"] = title
        return {"ok": True, "video_id": "EP", "url": "https://www.youtube.com/watch?v=EP"}

    monkeypatch.setattr(youtube_publish, "_upload_video", fake_upload)
    _connect_ig()
    r = _reel(client, kind="episode", title="Episodio 16",
              targets=[{"platform": "youtube", "caption": "notas"}, {"platform": "tiktok", "caption": ""}])
    assert "el episodio completo va a" in r.get_json()["error"]
    r = _reel(client, kind="episode", title="Episodio 16", scheduled_at="2099-01-01T00:00:00Z",
              targets=[{"platform": "youtube", "caption": "notas"}])
    post = r.get_json()["posts"][0]
    assert post["kind"] == "episode" and post["status"] == "scheduled"
    conn = pubpod._db(SLUG)
    conn.execute("UPDATE pub_posts SET scheduled_at=1")
    conn.commit()
    conn.close()
    pubpod.run_due(SLUG)
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert seen["title"] == "Episodio 16"
    assert post["result_url"] == "https://www.youtube.com/watch?v=EP"


def _upload_named(client, name, data=b"x" * 20):
    r = client.post("/api/mac/uploads", json={"filename": name, "size": len(data)})
    uid = r.get_json()["upload_id"]
    client.put(f"/api/mac/uploads/{uid}/chunk?index=0", data=data)
    assert client.post(f"/api/mac/uploads/{uid}/finish").status_code == 200
    return uid


def test_feed_puts_audio_in_feed_and_updates_notes(client, monkeypatch):
    monkeypatch.setattr(pubpod, "load_shared_config", lambda: dict(CFG, hosting={"host": "h"}))
    conn = db_mod.get_db(SLUG)
    ep = conn.execute("INSERT INTO episodes (title) VALUES ('Episodio 16')").lastrowid
    conn.commit()
    conn.close()
    seen = {}
    import episodes

    def fake_upload(slug, ep_id, path):
        seen["path"] = str(path)
        return {"ok": True, "media_url": "https://media/ep016.mp3"}

    monkeypatch.setattr(episodes, "upload_episode_media", fake_upload)
    body = {"slug": SLUG, "upload_id": _upload_named(client, "ep16.mp3"), "title": "Episodio 16",
            "kind": "episode", "episode_id": ep, "targets": [{"platform": "feed", "caption": "Notas nuevas"}]}
    r = client.post("/api/pubpod/reels", json=body)
    assert r.status_code == 201, r.get_json()
    pubpod.run_due(SLUG)
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "published" and post["result_url"] == "https://media/ep016.mp3"
    assert seen["path"].endswith(".mp3")
    conn = db_mod.get_db(SLUG)
    assert conn.execute("SELECT description FROM episodes WHERE id=?", (ep,)).fetchone()[0] == "Notas nuevas"
    conn.close()


def test_feed_needs_linked_episode(client, monkeypatch):
    monkeypatch.setattr(pubpod, "load_shared_config", lambda: dict(CFG, hosting={"host": "h"}))
    body = {"slug": SLUG, "upload_id": _upload_named(client, "ep.mp3"), "title": "E",
            "kind": "episode", "targets": [{"platform": "feed", "caption": ""}]}
    assert "vinculado" in client.post("/api/pubpod/reels", json=body).get_json()["error"]


def test_instagram_cover_image(client, monkeypatch):
    _connect_ig()
    body = {"slug": SLUG, "upload_id": _upload_named(client, "portada.jpg"), "title": "Episodio 16",
            "kind": "episode", "targets": [{"platform": "instagram_image", "caption": "Nuevo episodio"}]}
    assert client.post("/api/pubpod/reels", json=body).status_code == 201
    token = pubpod._db(SLUG).execute("SELECT media_token FROM pub_posts").fetchone()[0]
    r = client.get(f"/pub/m/{SLUG}/{token}.jpg")
    assert r.status_code == 200 and r.mimetype == "image/jpeg"
    sent = {}

    def fake_post(url, data=None, timeout=None):
        if url.endswith("/17841/media"):
            sent.update(data)
            return _resp(200, {"id": "C1"})
        return _resp(200, {"id": "M1"})

    monkeypatch.setattr(pubpod.requests, "post", fake_post)
    monkeypatch.setattr(pubpod.requests, "get", lambda url, params=None, timeout=None:
                        _resp(200, {"status_code": "FINISHED", "permalink": "https://www.instagram.com/p/x/"}))
    pubpod.run_due(SLUG)
    assert sent["image_url"].endswith(f"/pub/m/{SLUG}/{token}.jpg") and "media_type" not in sent
    post = client.get(f"/api/pubpod/podcasts/{SLUG}/posts").get_json()["posts"][0]
    assert post["status"] == "published"


def test_reel_cannot_go_to_feed(client):
    body = {"slug": SLUG, "upload_id": _upload_named(client, "r.mp4"), "title": "R",
            "targets": [{"platform": "feed", "caption": ""}]}
    assert "un reel va a" in client.post("/api/pubpod/reels", json=body).get_json()["error"]
