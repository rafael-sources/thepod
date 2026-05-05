"""Unit tests for hosting.py — URL construction and config validation."""

import pytest
from unittest.mock import patch


def test_build_remote_path():
    """Remote path combines upload_path + slug + filename."""
    mock_cfg = {
        "host": "1.2.3.4",
        "user": "podpod",
        "ssh_key": "~/.ssh/id_contabo",
        "base_url": "https://media.thepod.rtfb.space",
        "upload_path": "/var/www/media/podcasts/",
    }
    with patch("hosting.load_shared_config", return_value={"hosting": mock_cfg}):
        from hosting import _build_remote_path
        result = _build_remote_path("mi-podcast", "ep01-final.mp3")
        assert result == "/var/www/media/podcasts/mi-podcast/ep01-final.mp3"


def test_build_remote_path_strips_trailing_slash():
    mock_cfg = {
        "host": "x", "user": "x", "ssh_key": "x",
        "base_url": "https://x", "upload_path": "/var/www/media/podcasts",
    }
    with patch("hosting.load_shared_config", return_value={"hosting": mock_cfg}):
        from hosting import _build_remote_path
        result = _build_remote_path("slug", "file.mp3")
        assert result == "/var/www/media/podcasts/slug/file.mp3"


def test_build_public_url():
    from hosting import _build_public_url
    cfg = {
        "base_url": "https://media.thepod.rtfb.space",
        "upload_path": "/var/www/media/podcasts/",
    }
    result = _build_public_url(cfg, "mi-podcast", "ep01-final.mp3")
    assert result == "https://media.thepod.rtfb.space/mi-podcast/ep01-final.mp3"


def test_build_public_url_strips_trailing_slash():
    from hosting import _build_public_url
    cfg = {"base_url": "https://media.thepod.rtfb.space/", "upload_path": "/x/"}
    result = _build_public_url(cfg, "pod", "f.mp3")
    assert result == "https://media.thepod.rtfb.space/pod/f.mp3"


def test_get_hosting_config_missing():
    with patch("hosting.load_shared_config", return_value={"secret_key": "x"}):
        from hosting import _get_hosting_config
        assert _get_hosting_config() is None


def test_get_hosting_config_empty_host():
    with patch("hosting.load_shared_config", return_value={"hosting": {"host": ""}}):
        from hosting import _get_hosting_config
        assert _get_hosting_config() is None


def test_get_hosting_config_present():
    cfg = {
        "hosting": {
            "host": "1.2.3.4",
            "user": "podpod",
            "ssh_key": "~/.ssh/id_contabo",
            "base_url": "https://media.thepod.rtfb.space",
            "upload_path": "/var/www/media/podcasts/",
        },
    }
    with patch("hosting.load_shared_config", return_value=cfg):
        from hosting import _get_hosting_config
        result = _get_hosting_config()
        assert result["host"] == "1.2.3.4"


def test_upload_file_no_config(tmp_path):
    """upload_file returns error when hosting not configured."""
    f = tmp_path / "test.mp3"
    f.write_bytes(b"data")
    with patch("hosting.load_shared_config", return_value={}):
        from hosting import upload_file
        result = upload_file("pod", str(f), "test.mp3")
        assert not result["ok"]
        assert "no configurado" in result["error"].lower()


def test_upload_file_missing_file():
    """upload_file returns error when local file doesn't exist."""
    cfg = {"hosting": {"host": "x", "user": "x", "ssh_key": "~/.ssh/x", "base_url": "https://x", "upload_path": "/x/"}}
    with patch("hosting.load_shared_config", return_value=cfg):
        from hosting import upload_file
        result = upload_file("pod", "/nonexistent/file.mp3", "file.mp3")
        assert not result["ok"]
        assert "no encontrado" in result["error"].lower()
