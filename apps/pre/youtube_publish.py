"""
Optional YouTube upload via Data API v3.

Requires:
- google-api-python-client, google-auth-oauthlib (pip install)
- OAuth2 credentials at ~/.podpod/youtube_credentials.json
- YouTube config in ~/.podpod/config.json under "youtube" key

Config structure in ~/.podpod/config.json:
{
  "youtube": {
    "enabled": false,
    "credentials_file": "~/.podpod/youtube_credentials.json",
    "default_category": "22",
    "default_privacy": "public"
  }
}
"""

from __future__ import annotations

import json
from pathlib import Path

from shared_config import load_shared_config


def _get_youtube_config() -> dict | None:
    """Return YouTube config dict or None if not configured/disabled."""
    cfg = load_shared_config()
    yt = cfg.get("youtube")
    if not yt or not yt.get("enabled"):
        return None
    return yt


def _get_credentials(config: dict):
    """Load OAuth2 credentials from the configured file."""
    from google.oauth2.credentials import Credentials
    creds_file = Path(config["credentials_file"]).expanduser()
    if not creds_file.exists():
        raise FileNotFoundError(f"YouTube credentials not found: {creds_file}")
    creds_data = json.loads(creds_file.read_text())
    return Credentials.from_authorized_user_info(creds_data)


def upload_video(
    video_path: str | Path,
    title: str,
    description: str,
    category: str | None = None,
    privacy: str | None = None,
    thumbnail_path: str | Path | None = None,
) -> dict:
    """Upload video to YouTube.

    Returns: {"ok": True, "video_id": "...", "url": "..."} or {"ok": False, "error": "..."}
    """
    config = _get_youtube_config()
    if not config:
        return {"ok": False, "error": "YouTube no configurado o deshabilitado"}

    video_path = Path(video_path)
    if not video_path.is_file():
        return {"ok": False, "error": f"Video no encontrado: {video_path}"}

    try:
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload

        credentials = _get_credentials(config)
        youtube = build("youtube", "v3", credentials=credentials)

        body = {
            "snippet": {
                "title": title[:100],
                "description": description[:5000],
                "categoryId": category or config.get("default_category", "22"),
            },
            "status": {
                "privacyStatus": privacy or config.get("default_privacy", "public"),
            },
        }

        media = MediaFileUpload(str(video_path), resumable=True, chunksize=10 * 1024 * 1024)
        req = youtube.videos().insert(part="snippet,status", body=body, media_body=media)

        response = None
        while response is None:
            _, response = req.next_chunk()

        video_id = response["id"]

        if thumbnail_path:
            thumb = Path(thumbnail_path)
            if thumb.is_file():
                youtube.thumbnails().set(
                    videoId=video_id,
                    media_body=MediaFileUpload(str(thumb)),
                ).execute()

        return {"ok": True, "video_id": video_id, "url": f"https://www.youtube.com/watch?v={video_id}"}

    except FileNotFoundError as e:
        return {"ok": False, "error": str(e)}
    except ImportError:
        return {"ok": False, "error": "google-api-python-client no instalado. pip install google-api-python-client google-auth-oauthlib"}
    except Exception as e:
        return {"ok": False, "error": f"YouTube upload failed: {str(e)[:300]}"}
