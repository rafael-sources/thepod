"""
YouTube upload via Data API v3 with per-podcast OAuth tokens.

OAuth flow:
    GET  /api/youtube/auth-url?slug=<slug>  — get Google auth URL
    GET  /api/youtube/callback              — handle Google redirect, store tokens
    GET  /api/youtube/status?slug=<slug>    — check connection status
    POST /api/youtube/disconnect            — remove stored tokens
    POST /api/youtube/upload                — trigger video upload

Config in ~/.podpod/config.json:
{
  "youtube": {
    "client_id": "...",
    "client_secret": "...",
    "redirect_uri": "https://prepod.castmedia.space/api/youtube/callback"
  }
}

Per-podcast tokens stored in the podcast's SQLite DB (youtube_tokens table).
"""

from __future__ import annotations

from pathlib import Path

from flask import Blueprint, jsonify, request

from auth import require_auth
from db import get_db
from shared_config import load_shared_config

bp = Blueprint("youtube", __name__)

SCOPES = [
    "https://www.googleapis.com/auth/youtube.upload",
    "https://www.googleapis.com/auth/youtube.readonly",
]


def _get_youtube_config() -> dict | None:
    cfg = load_shared_config()
    yt = cfg.get("youtube")
    if not yt or not yt.get("client_id"):
        return None
    return yt


def _ensure_youtube_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS youtube_tokens (
            id            INTEGER PRIMARY KEY CHECK (id = 1),
            access_token  TEXT,
            refresh_token TEXT,
            token_uri     TEXT DEFAULT 'https://oauth2.googleapis.com/token',
            channel_name  TEXT,
            channel_id    TEXT,
            connected_at  TEXT DEFAULT (datetime('now'))
        )
    """)
    conn.commit()


def _get_stored_tokens(slug: str) -> dict | None:
    db = get_db(slug)
    try:
        _ensure_youtube_table(db)
        row = db.execute("SELECT * FROM youtube_tokens WHERE id=1").fetchone()
        if row and row["refresh_token"]:
            return dict(row)
        return None
    finally:
        db.close()


def _save_tokens(slug: str, access_token: str, refresh_token: str,
                 channel_name: str = "", channel_id: str = ""):
    db = get_db(slug)
    try:
        _ensure_youtube_table(db)
        db.execute("DELETE FROM youtube_tokens")
        db.execute(
            """INSERT INTO youtube_tokens (id, access_token, refresh_token, channel_name, channel_id)
               VALUES (1, ?, ?, ?, ?)""",
            (access_token, refresh_token, channel_name, channel_id),
        )
        db.commit()
    finally:
        db.close()


def _delete_tokens(slug: str):
    db = get_db(slug)
    try:
        _ensure_youtube_table(db)
        db.execute("DELETE FROM youtube_tokens")
        db.commit()
    finally:
        db.close()


def _build_credentials(tokens: dict, yt_config: dict):
    from google.oauth2.credentials import Credentials
    return Credentials(
        token=tokens["access_token"],
        refresh_token=tokens["refresh_token"],
        token_uri=tokens.get("token_uri") or "https://oauth2.googleapis.com/token",
        client_id=yt_config["client_id"],
        client_secret=yt_config["client_secret"],
        scopes=SCOPES,
    )


def _fetch_channel_info(credentials) -> tuple[str, str]:
    from googleapiclient.discovery import build
    youtube = build("youtube", "v3", credentials=credentials)
    resp = youtube.channels().list(part="snippet", mine=True).execute()
    items = resp.get("items", [])
    if items:
        return items[0]["snippet"]["title"], items[0]["id"]
    return "", ""


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@bp.get("/api/youtube/auth-url")
@require_auth
def get_auth_url():
    slug = request.args.get("slug", "").strip()
    if not slug:
        return jsonify({"error": "slug requerido"}), 400

    yt_config = _get_youtube_config()
    if not yt_config:
        return jsonify({"error": "YouTube no configurado en el servidor"}), 500

    from google_auth_oauthlib.flow import Flow
    flow = Flow.from_client_config(
        {
            "web": {
                "client_id": yt_config["client_id"],
                "client_secret": yt_config["client_secret"],
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
                "redirect_uris": [yt_config["redirect_uri"]],
            }
        },
        scopes=SCOPES,
    )
    flow.redirect_uri = yt_config["redirect_uri"]

    auth_url, state = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",
        state=slug,
    )

    return jsonify({"auth_url": auth_url})


@bp.get("/api/youtube/callback")
def youtube_callback():
    error = request.args.get("error")
    if error:
        return f"<h3>Error de autorización: {error}</h3><p>Puedes cerrar esta ventana.</p>", 400

    code = request.args.get("code")
    slug = request.args.get("state", "").strip()
    if not code or not slug:
        return "<h3>Faltan parámetros</h3>", 400

    yt_config = _get_youtube_config()
    if not yt_config:
        return "<h3>YouTube no configurado</h3>", 500

    try:
        from google_auth_oauthlib.flow import Flow
        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": yt_config["client_id"],
                    "client_secret": yt_config["client_secret"],
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                    "redirect_uris": [yt_config["redirect_uri"]],
                }
            },
            scopes=SCOPES,
        )
        flow.redirect_uri = yt_config["redirect_uri"]
        flow.fetch_token(code=code)

        creds = flow.credentials
        channel_name, channel_id = "", ""
        try:
            channel_name, channel_id = _fetch_channel_info(creds)
        except Exception:
            pass

        _save_tokens(
            slug,
            access_token=creds.token,
            refresh_token=creds.refresh_token,
            channel_name=channel_name,
            channel_id=channel_id,
        )

        return (
            "<html><body style='font-family:system-ui;text-align:center;padding:60px;'>"
            f"<h2>Canal conectado: {channel_name or 'YouTube'}</h2>"
            "<p>Puedes cerrar esta ventana y volver a prePod.</p>"
            "<script>window.opener && window.opener.postMessage('youtube-connected','*'); setTimeout(()=>window.close(), 2000);</script>"
            "</body></html>"
        )

    except Exception as e:
        return f"<h3>Error al conectar YouTube</h3><p>{str(e)[:300]}</p>", 500


@bp.get("/api/youtube/status")
@require_auth
def youtube_status():
    slug = request.args.get("slug", "").strip()
    if not slug:
        return jsonify({"error": "slug requerido"}), 400

    tokens = _get_stored_tokens(slug)
    if not tokens:
        return jsonify({"connected": False})

    return jsonify({
        "connected": True,
        "channel_name": tokens.get("channel_name") or "",
        "channel_id": tokens.get("channel_id") or "",
        "connected_at": tokens.get("connected_at") or "",
    })


@bp.post("/api/youtube/disconnect")
@require_auth
def youtube_disconnect():
    data = request.get_json(silent=True) or {}
    slug = data.get("slug", "").strip()
    if not slug:
        return jsonify({"error": "slug requerido"}), 400

    _delete_tokens(slug)
    return jsonify({"ok": True})


def _upload_video(slug: str, video_path, title: str, description: str = "",
                  privacy: str = "public", category: str = "22",
                  progress_cb=None) -> dict:
    """Upload a video to YouTube with the podcast's OAuth tokens.

    progress_cb (optional) receives a float 0.0–1.0 on each uploaded chunk.
    Returns {"ok": True, "video_id": ..., "url": ...} or {"ok": False, "error": ...}.
    """
    yt_config = _get_youtube_config()
    if not yt_config:
        return {"ok": False, "error": "YouTube no configurado"}

    tokens = _get_stored_tokens(slug)
    if not tokens:
        return {"ok": False, "error": "YouTube no conectado para este podcast"}

    video_file = Path(video_path)
    if not video_file.is_file():
        return {"ok": False, "error": f"Video no encontrado: {video_path}"}

    try:
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload

        credentials = _build_credentials(tokens, yt_config)
        youtube = build("youtube", "v3", credentials=credentials)

        body = {
            "snippet": {
                "title": title[:100],
                "description": description[:5000],
                "categoryId": category,
            },
            "status": {
                "privacyStatus": privacy,
            },
        }

        media = MediaFileUpload(str(video_file), resumable=True, chunksize=10 * 1024 * 1024)
        req = youtube.videos().insert(part="snippet,status", body=body, media_body=media)

        response = None
        while response is None:
            status, response = req.next_chunk()
            if status and progress_cb:
                progress_cb(status.progress())

        video_id = response["id"]

        if credentials.token != tokens["access_token"]:
            _save_tokens(
                slug,
                access_token=credentials.token,
                refresh_token=credentials.refresh_token or tokens["refresh_token"],
                channel_name=tokens.get("channel_name", ""),
                channel_id=tokens.get("channel_id", ""),
            )

        return {"ok": True, "video_id": video_id,
                "url": f"https://www.youtube.com/watch?v={video_id}"}

    except ImportError:
        return {"ok": False, "error": "Instala: pip install google-api-python-client google-auth-oauthlib"}
    except Exception as e:
        return {"ok": False, "error": f"Upload fallido: {str(e)[:300]}"}


@bp.post("/api/youtube/upload")
@require_auth
def youtube_upload():
    data = request.get_json(silent=True) or {}
    slug = data.get("slug", "").strip()
    video_path = data.get("video_path", "").strip()
    title = data.get("title", "").strip()
    description = data.get("description", "")

    if not slug or not video_path or not title:
        return jsonify({"ok": False, "error": "slug, video_path y title son requeridos"}), 400

    result = _upload_video(
        slug, video_path, title, description,
        privacy=data.get("privacy", "public"),
        category=data.get("category", "22"),
    )

    if not result["ok"]:
        error = result["error"]
        if error == "YouTube no configurado":
            return jsonify(result), 500
        if error == "YouTube no conectado para este podcast":
            return jsonify(result), 400
        if error.startswith("Video no encontrado"):
            return jsonify(result), 404
        return jsonify(result), 500

    return jsonify(result)
