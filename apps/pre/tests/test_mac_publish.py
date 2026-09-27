"""Tests for mac_publish.py — chunked uploads and publish jobs for the Mac app."""

import io
import json
import os
import sys
import time
from pathlib import Path
from unittest.mock import patch

import pytest
from flask import Flask

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config
import db as db_mod
import mac_publish


@pytest.fixture
def client(tmp_path):
    """Flask test client with mac_publish registered and PODCASTS_DIR sandboxed."""
    podcasts_dir = tmp_path / "podcasts"
    podcasts_dir.mkdir()

    orig_cfg = config.PODCASTS_DIR
    orig_db = db_mod.PODCASTS_DIR
    orig_mac = mac_publish.PODCASTS_DIR
    config.PODCASTS_DIR = podcasts_dir
    db_mod.PODCASTS_DIR = podcasts_dir
    mac_publish.PODCASTS_DIR = podcasts_dir

    app = Flask(__name__)
    app.secret_key = "test"
    app.register_blueprint(mac_publish.bp)

    with app.test_client() as c:
        with c.session_transaction() as s:
            s["username"] = "tester"
        yield c

    config.PODCASTS_DIR = orig_cfg
    db_mod.PODCASTS_DIR = orig_db
    mac_publish.PODCASTS_DIR = orig_mac
    mac_publish._jobs.clear()


def _init_upload(client, filename="episodio.mp3", size=10):
    resp = client.post("/api/mac/uploads", json={"filename": filename, "size": size})
    assert resp.status_code == 200, resp.get_json()
    return resp.get_json()["upload_id"]


def test_upload_requires_auth(client):
    with client.session_transaction() as s:
        s.clear()
    resp = client.post("/api/mac/uploads", json={"filename": "a.mp3", "size": 1})
    assert resp.status_code == 401


def test_upload_init_validates_payload(client):
    resp = client.post("/api/mac/uploads", json={"filename": "", "size": 0})
    assert resp.status_code == 400


def test_chunked_upload_flow(client):
    data = b"0123456789"
    upload_id = _init_upload(client, filename="episodio.mp3", size=len(data))

    r1 = client.put(f"/api/mac/uploads/{upload_id}/chunk?index=0", data=data[:6])
    assert r1.status_code == 200
    assert r1.get_json()["received"] == 6

    r2 = client.put(f"/api/mac/uploads/{upload_id}/chunk?index=1", data=data[6:])
    assert r2.status_code == 200
    assert r2.get_json()["received"] == 10

    rf = client.post(f"/api/mac/uploads/{upload_id}/finish")
    assert rf.status_code == 200
    assert rf.get_json()["ok"] is True

    # Stored file keeps the original suffix so downstream naming/mimetypes work.
    stored = mac_publish.PODCASTS_DIR / "_uploads" / f"{upload_id}.mp3"
    assert stored.read_bytes() == data


def test_chunk_out_of_order_is_rejected(client):
    upload_id = _init_upload(client, size=4)
    resp = client.put(f"/api/mac/uploads/{upload_id}/chunk?index=1", data=b"ab")
    assert resp.status_code == 409


def test_chunk_unknown_upload_is_404(client):
    resp = client.put("/api/mac/uploads/nope/chunk?index=0", data=b"ab")
    assert resp.status_code == 404


def test_finish_size_mismatch_is_rejected(client):
    upload_id = _init_upload(client, size=99)
    client.put(f"/api/mac/uploads/{upload_id}/chunk?index=0", data=b"ab")
    resp = client.post(f"/api/mac/uploads/{upload_id}/finish")
    assert resp.status_code == 400
    assert "tamaño" in resp.get_json()["error"].lower()


def test_stale_uploads_are_cleaned_on_init(client):
    uploads = mac_publish.PODCASTS_DIR / "_uploads"
    uploads.mkdir(exist_ok=True)
    old = uploads / "deadbeef.part"
    old.write_bytes(b"x")
    old_meta = uploads / "deadbeef.json"
    old_meta.write_text("{}")
    stale = time.time() - (25 * 3600)
    os.utime(old, (stale, stale))
    os.utime(old_meta, (stale, stale))

    fresh = uploads / "cafebabe.part"
    fresh.write_bytes(b"y")

    _init_upload(client)

    assert not old.exists()
    assert not old_meta.exists()
    assert fresh.exists()


def test_upload_size_over_cap_is_rejected(client):
    resp = client.post("/api/mac/uploads",
                       json={"filename": "big.mp4", "size": mac_publish.UPLOAD_MAX + 1})
    assert resp.status_code == 413


def test_weird_suffix_falls_back_to_bin(client):
    data = b"xx"
    upload_id = _init_upload(client, filename="raro.mp3 x", size=len(data))
    client.put(f"/api/mac/uploads/{upload_id}/chunk?index=0", data=data)
    resp = client.post(f"/api/mac/uploads/{upload_id}/finish")
    assert resp.status_code == 200
    stored = mac_publish.PODCASTS_DIR / "_uploads" / f"{upload_id}.bin"
    assert stored.read_bytes() == data


def test_job_lifecycle_helpers(client):
    job_id = mac_publish._create_job()
    body = client.get(f"/api/mac/jobs/{job_id}").get_json()
    assert body == {"status": "queued", "progress": 0.0, "result": None, "error": None}

    mac_publish._update_job(job_id, status="running", progress=0.5)
    body = client.get(f"/api/mac/jobs/{job_id}").get_json()
    assert body["status"] == "running"
    assert body["progress"] == 0.5

    mac_publish._update_job(job_id, status="done", progress=1.0,
                            result={"media_url": "https://x/y.mp3"})
    body = client.get(f"/api/mac/jobs/{job_id}").get_json()
    assert body["status"] == "done"
    assert body["result"]["media_url"] == "https://x/y.mp3"


def test_unknown_job_is_404(client):
    assert client.get("/api/mac/jobs/nope").status_code == 404


def _make_podcast(slug="test-pod", ep_title="Ep 1", ep_number=7):
    """Create a podcast dir + DB with one episode. PODCASTS_DIR must already be patched."""
    pod_dir = config.PODCASTS_DIR / slug
    pod_dir.mkdir(parents=True, exist_ok=True)
    conn = db_mod.get_db(slug)
    conn.execute(
        "INSERT INTO podcast_meta (name, slug, description, owner_username) VALUES (?, ?, 'desc', 'tester')",
        (slug, slug),
    )
    conn.execute(
        "INSERT INTO episodes (title, status, episode_number) VALUES (?, 'recorded', ?)",
        (ep_title, ep_number),
    )
    ep_id = conn.execute("SELECT id FROM episodes ORDER BY id DESC LIMIT 1").fetchone()["id"]
    conn.commit()
    conn.close()
    return slug, ep_id


def test_upload_episode_media_success(client, tmp_path):
    import episodes
    slug, ep_id = _make_podcast()
    media = tmp_path / "final.mp3"
    media.write_bytes(b"mp3data")

    with patch("hosting.upload_file",
               return_value={"ok": True, "url": "https://media.example/test-pod/ep007-test-pod.mp3"}) as up:
        result = episodes.upload_episode_media(slug, ep_id, media)

    assert result["ok"] is True
    assert result["media_url"].endswith("ep007-test-pod.mp3")
    # Same filename convention as the existing publish endpoint.
    assert up.call_args[0][2] == "ep007-test-pod.mp3"

    conn = db_mod.get_db(slug)
    row = conn.execute("SELECT status, media_url FROM episodes WHERE id=?", (ep_id,)).fetchone()
    conn.close()
    assert row["status"] == "published"
    assert row["media_url"] == result["media_url"]


def test_upload_episode_media_missing_episode(client, tmp_path):
    import episodes
    slug, _ = _make_podcast()
    media = tmp_path / "final.mp3"
    media.write_bytes(b"x")
    result = episodes.upload_episode_media(slug, 999, media)
    assert result["ok"] is False
    assert "no encontrado" in result["error"]


def test_upload_episode_media_missing_file(client, tmp_path):
    import episodes
    slug, ep_id = _make_podcast()
    result = episodes.upload_episode_media(slug, ep_id, tmp_path / "no-existe.mp3")
    assert result["ok"] is False
    assert result["error"].startswith("Archivo no encontrado")
