"""Tests for distribution.py — platform connection management."""

import sqlite3
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config
import db as db_mod
import distribution


def _setup_db(tmp_path, with_cover=True, with_episode=True):
    """Create a minimal podcast DB and return (slug, podcasts_dir)."""
    slug = "test-pod"
    podcasts_dir = tmp_path / "podcasts"
    pod_dir = podcasts_dir / slug
    pod_dir.mkdir(parents=True)

    orig = config.PODCASTS_DIR
    config.PODCASTS_DIR = podcasts_dir
    db_mod.PODCASTS_DIR = podcasts_dir
    distribution.PODCASTS_DIR = podcasts_dir
    try:
        conn = db_mod.get_db(slug)
        conn.execute(
            """INSERT INTO podcast_meta (name, slug, description, tagline, shared_project_id, cover_filename)
               VALUES ('Test Pod', ?, 'A test podcast for distribution', 'tag', ?, ?)""",
            (slug, f"proj-{id(tmp_path)}", "cover.jpg" if with_cover else None),
        )
        conn.execute(
            "INSERT INTO landing_config (owner_name, owner_email) VALUES ('Host', 'h@t.com')"
        )
        if with_episode:
            conn.execute(
                "INSERT INTO episodes (title, status, media_url) VALUES ('Ep 1', 'published', 'https://thepod.contenido.space/test-pod/ep1.mp4')"
            )
        conn.commit()
        conn.close()
    finally:
        config.PODCASTS_DIR = orig
        db_mod.PODCASTS_DIR = orig
        distribution.PODCASTS_DIR = orig
    return slug, podcasts_dir


@pytest.fixture(autouse=True)
def _patch_podcasts_dir(tmp_path):
    """Ensure config.PODCASTS_DIR is restored after each test."""
    yield


class TestValidation:
    def test_valid_feed(self, tmp_path):
        slug, podcasts_dir = _setup_db(tmp_path)
        config.PODCASTS_DIR = podcasts_dir
        db_mod.PODCASTS_DIR = podcasts_dir
        distribution.PODCASTS_DIR = podcasts_dir
        try:
            result = distribution._validate_feed_requirements(slug)
        finally:
            config.PODCASTS_DIR = Path("/srv/thepod/prepod-data/podcasts")
            db_mod.PODCASTS_DIR = config.PODCASTS_DIR
            distribution.PODCASTS_DIR = config.PODCASTS_DIR
        assert result["valid"] is True
        assert len(result["issues"]) == 0

    def test_missing_cover(self, tmp_path):
        slug, podcasts_dir = _setup_db(tmp_path, with_cover=False)
        config.PODCASTS_DIR = podcasts_dir
        db_mod.PODCASTS_DIR = podcasts_dir
        distribution.PODCASTS_DIR = podcasts_dir
        try:
            result = distribution._validate_feed_requirements(slug)
        finally:
            config.PODCASTS_DIR = Path("/srv/thepod/prepod-data/podcasts")
            db_mod.PODCASTS_DIR = config.PODCASTS_DIR
            distribution.PODCASTS_DIR = config.PODCASTS_DIR
        assert result["valid"] is False
        assert any("portada" in i.lower() or "artwork" in i.lower() for i in result["issues"])

    def test_no_episodes(self, tmp_path):
        slug, podcasts_dir = _setup_db(tmp_path, with_episode=False)
        config.PODCASTS_DIR = podcasts_dir
        db_mod.PODCASTS_DIR = podcasts_dir
        distribution.PODCASTS_DIR = podcasts_dir
        try:
            result = distribution._validate_feed_requirements(slug)
        finally:
            config.PODCASTS_DIR = Path("/srv/thepod/prepod-data/podcasts")
            db_mod.PODCASTS_DIR = config.PODCASTS_DIR
            distribution.PODCASTS_DIR = config.PODCASTS_DIR
        assert result["valid"] is False
        assert any("episodio" in i.lower() for i in result["issues"])


class TestDistributionTable:
    def test_create_and_query(self, tmp_path):
        slug, podcasts_dir = _setup_db(tmp_path)
        config.PODCASTS_DIR = podcasts_dir
        db_mod.PODCASTS_DIR = podcasts_dir
        try:
            conn = db_mod.get_db(slug)
            distribution._ensure_distribution_table(conn)
            conn.execute(
                "INSERT INTO distribution_platforms (platform, status) VALUES ('spotify', 'pending')"
            )
            conn.commit()
            row = conn.execute("SELECT * FROM distribution_platforms WHERE platform='spotify'").fetchone()
            conn.close()
        finally:
            config.PODCASTS_DIR = Path("/srv/thepod/prepod-data/podcasts")
            db_mod.PODCASTS_DIR = config.PODCASTS_DIR
        assert row["status"] == "pending"
        data = distribution._serialize_platform(row)
        assert data["platform"] == "spotify"
        assert data["status"] == "pending"

    def test_update_to_connected(self, tmp_path):
        slug, podcasts_dir = _setup_db(tmp_path)
        config.PODCASTS_DIR = podcasts_dir
        db_mod.PODCASTS_DIR = podcasts_dir
        try:
            conn = db_mod.get_db(slug)
            distribution._ensure_distribution_table(conn)
            conn.execute(
                "INSERT INTO distribution_platforms (platform, status) VALUES ('apple', 'pending')"
            )
            conn.execute(
                "UPDATE distribution_platforms SET status='connected', external_url='https://apple.com/123' WHERE platform='apple'"
            )
            conn.commit()
            row = conn.execute("SELECT * FROM distribution_platforms WHERE platform='apple'").fetchone()
            conn.close()
        finally:
            config.PODCASTS_DIR = Path("/srv/thepod/prepod-data/podcasts")
            db_mod.PODCASTS_DIR = config.PODCASTS_DIR
        assert row["status"] == "connected"
        assert row["external_url"] == "https://apple.com/123"

    def test_platform_constraint(self, tmp_path):
        slug, podcasts_dir = _setup_db(tmp_path)
        config.PODCASTS_DIR = podcasts_dir
        db_mod.PODCASTS_DIR = podcasts_dir
        try:
            conn = db_mod.get_db(slug)
            distribution._ensure_distribution_table(conn)
            with pytest.raises(sqlite3.IntegrityError):
                conn.execute(
                    "INSERT INTO distribution_platforms (platform, status) VALUES ('invalid', 'pending')"
                )
            conn.close()
        finally:
            config.PODCASTS_DIR = Path("/srv/thepod/prepod-data/podcasts")
            db_mod.PODCASTS_DIR = config.PODCASTS_DIR


class TestPlatformInfo:
    def test_platforms_dict(self):
        assert "spotify" in distribution.PLATFORMS
        assert "apple" in distribution.PLATFORMS
        assert "youtube" in distribution.PLATFORMS
        assert distribution.PLATFORMS["spotify"]["submit_url"] is not None
        assert distribution.PLATFORMS["apple"]["submit_url"] is not None
        assert distribution.PLATFORMS["youtube"]["submit_url"] is None

    def test_feed_url_construction(self):
        with patch("shared_config.load_shared_config", return_value={"prepod_url": "https://prepod.example.com"}):
            url = distribution._get_feed_url("my-podcast")
        assert url == "https://prepod.example.com/landing/my-podcast/feed.xml"

    def test_feed_url_fallback(self):
        with patch("shared_config.load_shared_config", return_value={}):
            url = distribution._get_feed_url("my-podcast")
        assert url == "/landing/my-podcast/feed.xml"
