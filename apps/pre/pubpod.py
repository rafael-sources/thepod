"""
pubPod — publish and schedule reels on the podcast's social networks.

Networks: Instagram (API with Instagram Login), YouTube Shorts
(reuses the YouTube connection prePod already has) and TikTok (the reel lands in
the user's inbox and they publish it from the app; direct posting
requires TikTok's audit). Each network lives in its own "publisher" so it can
move from limited to full mode network by network.

Endpoints (thePod session):
    GET  /api/pubpod/networks                         networks available on the server
    GET  /api/pubpod/podcasts/<slug>/accounts         connected accounts
    GET  /api/pubpod/instagram/auth-url?slug=         URL to connect Instagram
    GET  /api/pubpod/instagram/callback               Instagram redirect back (public)
    POST /api/pubpod/podcasts/<slug>/accounts/<net>/disconnect
    POST /api/pubpod/reels                            {slug, upload_id, title, targets, scheduled_at, episode_id}
                                                      (the video is uploaded first via /api/mac/uploads, web and Mac)
    GET  /api/pubpod/podcasts/<slug>/posts
    POST /api/pubpod/podcasts/<slug>/posts/<id>/cancel
    POST /api/pubpod/podcasts/<slug>/posts/<id>/retry
    GET  /pub/m/<slug>/<token>.mp4                    temporary public video (Meta downloads it)

Config in ~/.podpod/config.json:
    "instagram": {"app_id": "...", "app_secret": "..."}
    "tiktok":    {"client_key": "...", "client_secret": "..."}
Redirects: <prepod_url>/api/pubpod/instagram/callback and .../tiktok/callback.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import requests
from flask import Blueprint, abort, jsonify, request, send_file, session
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from auth import require_auth
from config import PODCASTS_DIR, SECRET_KEY
from db import get_db
from pod_push import notify as push_notify
from shared_config import load_shared_config

bp = Blueprint("pubpod", __name__)

IG_GRAPH = "https://graph.instagram.com/v23.0"
IG_SCOPES = "instagram_business_basic,instagram_business_content_publish"
# Targets: instagram = Reels (video), instagram_image = the cover in the Instagram feed,
# youtube = Shorts (reel) or the full episode, tiktok, feed = the audio to the feed (Spotify and Apple Podcasts).
NETWORKS = ("instagram", "instagram_image", "youtube", "tiktok", "feed")
CAPTION_MAX = {"instagram": 2200, "instagram_image": 2200, "youtube": 5000, "tiktok": 2200, "feed": 20000}
FOR_KIND = {"reel": {"instagram", "youtube", "tiktok"},
            "episode": {"youtube", "feed", "instagram_image"}}
MEDIA_EXT = {"mp4", "mov", "mp3", "m4a", "jpg", "jpeg", "png"}
MIME = {"mp4": "video/mp4", "mov": "video/quicktime", "mp3": "audio/mpeg", "m4a": "audio/mp4",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}
TT_API = "https://open.tiktokapis.com/v2"
TT_SCOPES = "user.info.basic,video.upload"
MEDIA_KEEP_SECONDS = 7 * 24 * 3600
_TOKEN_RE = re.compile(r"[0-9a-f]{32}\Z")
_state = URLSafeTimedSerializer(SECRET_KEY, salt="pubpod-oauth")

SCHEMA = """
CREATE TABLE IF NOT EXISTS pub_accounts (
    platform      TEXT PRIMARY KEY,
    account_id    TEXT NOT NULL,
    username      TEXT,
    access_token  TEXT NOT NULL,
    expires_at    REAL,
    connected_by  TEXT,
    connected_at  TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS pub_posts (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id    INTEGER,
    title         TEXT NOT NULL,
    platform      TEXT NOT NULL,
    caption       TEXT NOT NULL DEFAULT '',
    media_token   TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'scheduled'
        CHECK(status IN ('scheduled','publishing','published','private','inbox','error','cancelled')),
    scheduled_at  REAL NOT NULL,
    result_url    TEXT,
    error         TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    created_by    TEXT,
    created_at    TEXT DEFAULT (datetime('now')),
    updated_at    TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_pub_posts_due ON pub_posts(status, scheduled_at);
"""


# ---------------------------------------------------------------------------
# Database and files
# ---------------------------------------------------------------------------

def _db(slug: str):
    conn = get_db(slug)
    conn.executescript(SCHEMA)
    _migrate(conn)
    return conn


def _migrate(conn):
    """Schema changes after the first version."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(pub_accounts)")}
    if "refresh_token" not in cols:
        conn.execute("ALTER TABLE pub_accounts ADD COLUMN refresh_token TEXT")
        conn.execute("ALTER TABLE pub_accounts ADD COLUMN refresh_expires_at REAL")
        conn.commit()
    sql = conn.execute("SELECT sql FROM sqlite_master WHERE name='pub_posts'").fetchone()[0]
    if "'inbox'" not in sql:   # TikTok leaves the reel in the user's inbox: new status
        conn.execute("DROP INDEX IF EXISTS idx_pub_posts_due")
        conn.execute("ALTER TABLE pub_posts RENAME TO pub_posts_old")
        conn.executescript(SCHEMA)
        cols = ", ".join(r[1] for r in conn.execute("PRAGMA table_info(pub_posts_old)"))
        conn.execute(f"INSERT INTO pub_posts ({cols}) SELECT {cols} FROM pub_posts_old")
        conn.execute("DROP TABLE pub_posts_old")
        conn.commit()
    conn.execute("""CREATE TABLE IF NOT EXISTS pub_prefs (
        platform TEXT PRIMARY KEY, signature TEXT NOT NULL DEFAULT '')""")
    if "kind" not in {r[1] for r in conn.execute("PRAGMA table_info(pub_posts)")}:
        # «reel» (vertical, Shorts) or «episode» (the full episode to YouTube)
        conn.execute("ALTER TABLE pub_posts ADD COLUMN kind TEXT NOT NULL DEFAULT 'reel'")
        conn.commit()


def _media_dir(slug: str) -> Path:
    d = PODCASTS_DIR / slug / "pubpod"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _media_path(slug: str, token: str) -> Path:
    """Stored file for that post (video, audio or image)."""
    d = _media_dir(slug)
    for f in d.glob(f"{token}.*"):
        if f.suffix[1:].lower() in MEDIA_EXT:
            return f
    return d / f"{token}.mp4"


def _media_url(slug: str, path: Path) -> str:
    base = (load_shared_config().get("prepod_url") or "").rstrip("/")
    return f"{base}/pub/m/{slug}/{path.name}"


def _public_media_url(slug: str, token: str) -> str:
    base = (load_shared_config().get("prepod_url") or request.host_url).rstrip("/")
    return f"{base}/pub/m/{slug}/{token}.mp4"


def _now() -> float:
    return time.time()


def _iso(ts):
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_when(value):
    """None/'' → now. ISO 8601 (with zone) → epoch. Error → ValueError."""
    if value in (None, "", "now"):
        return _now()
    s = str(value).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        raise ValueError("la fecha debe incluir zona horaria")
    return dt.timestamp()


# ---------------------------------------------------------------------------
# Per-podcast access (same rule as mac_publish)
# ---------------------------------------------------------------------------

def _access_error(slug: str):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", slug or ""):
        return jsonify({"error": "podcast inválido"}), 400
    from mac_publish import _podcast_access_error
    return _podcast_access_error(slug)


# ---------------------------------------------------------------------------
# Instagram: connection
# ---------------------------------------------------------------------------

def _ig_config():
    cfg = (load_shared_config().get("instagram") or {})
    if not cfg.get("app_id") or not cfg.get("app_secret"):
        return None
    return cfg


def _ig_redirect_uri():
    base = (load_shared_config().get("prepod_url") or "").rstrip("/")
    return f"{base}/api/pubpod/instagram/callback"


def _save_account(slug, platform, account_id, username, token, expires_at, user,
                  refresh_token=None, refresh_expires_at=None):
    conn = _db(slug)
    try:
        conn.execute(
            """INSERT INTO pub_accounts (platform, account_id, username, access_token, expires_at, connected_by,
                                         refresh_token, refresh_expires_at)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(platform) DO UPDATE SET account_id=excluded.account_id,
                 username=excluded.username, access_token=excluded.access_token,
                 expires_at=excluded.expires_at, connected_by=excluded.connected_by,
                 refresh_token=excluded.refresh_token, refresh_expires_at=excluded.refresh_expires_at,
                 connected_at=datetime('now')""",
            (platform, str(account_id), username, token, expires_at, user, refresh_token, refresh_expires_at),
        )
        conn.commit()
    finally:
        conn.close()


def _get_account(slug, platform):
    conn = _db(slug)
    try:
        row = conn.execute("SELECT * FROM pub_accounts WHERE platform=?", (platform,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def _ig_token(slug):
    """Current Instagram token; refreshes it if it expires in less than 7 days."""
    acc = _get_account(slug, "instagram")
    if not acc:
        return None, None
    exp = acc.get("expires_at") or 0
    if exp and exp - _now() < 7 * 24 * 3600:
        try:
            r = requests.get("https://graph.instagram.com/refresh_access_token",
                             params={"grant_type": "ig_refresh_token",
                                     "access_token": acc["access_token"]}, timeout=30)
            data = r.json()
            if r.ok and data.get("access_token"):
                acc["access_token"] = data["access_token"]
                acc["expires_at"] = _now() + int(data.get("expires_in") or 0)
                _save_account(slug, "instagram", acc["account_id"], acc.get("username"),
                              acc["access_token"], acc["expires_at"], acc.get("connected_by"))
        except (requests.RequestException, ValueError):
            pass
    return acc["access_token"], acc["account_id"]


@bp.get("/api/pubpod/networks")
@require_auth
def networks():
    from youtube_publish import _get_youtube_config
    return jsonify({
        "instagram": bool(_ig_config()),
        "youtube": bool(_get_youtube_config()),
        "tiktok": bool(_tt_config()),
        "feed": _feed_ready(),
        "facebook": False,
    })


@bp.get("/api/pubpod/podcasts/<slug>/accounts")
@require_auth
def accounts(slug):
    denied = _access_error(slug)
    if denied:
        return denied
    out = {}
    ig = _get_account(slug, "instagram")
    out["instagram"] = ({"connected": True, "username": ig.get("username"),
                         "expires_at": _iso(ig.get("expires_at"))}
                        if ig else {"connected": False})
    try:
        from youtube_publish import _get_stored_tokens
        yt = _get_stored_tokens(slug)
    except Exception:
        yt = None
    out["youtube"] = ({"connected": True, "username": yt.get("channel_name") or "YouTube"}
                      if yt else {"connected": False})
    tt = _get_account(slug, "tiktok")
    if tt and (tt.get("refresh_expires_at") or 0) < _now():
        tt = None   # the TikTok connection expired (lasts one year): must reconnect
    out["tiktok"] = ({"connected": True, "username": tt.get("username")} if tt else {"connected": False})
    out["feed"] = ({"connected": True, "username": "Feed del podcast"} if _feed_ready() else {"connected": False})
    out["facebook"] = {"connected": False}
    return jsonify(out)


@bp.get("/api/pubpod/instagram/auth-url")
@require_auth
def instagram_auth_url():
    slug = (request.args.get("slug") or "").strip()
    denied = _access_error(slug)
    if denied:
        return denied
    cfg = _ig_config()
    if not cfg:
        return jsonify({"error": "Instagram todavía no está habilitado en thePod"}), 503
    state = _state.dumps({"slug": slug, "user": session.get("username")})
    from urllib.parse import urlencode
    url = "https://www.instagram.com/oauth/authorize?" + urlencode({
        "client_id": cfg["app_id"],
        "redirect_uri": _ig_redirect_uri(),
        "response_type": "code",
        "scope": IG_SCOPES,
        "state": state,
    })
    return jsonify({"auth_url": url})


def _popup_page(title, body, ok):
    msg = "pubpod-connected" if ok else "pubpod-error"
    return (
        "<html><head><meta charset='utf-8'></head>"
        "<body style='font-family:system-ui;text-align:center;padding:60px;'>"
        f"<h2>{title}</h2><p>{body}</p>"
        f"<script>window.opener && window.opener.postMessage('{msg}','*');"
        "setTimeout(()=>window.close(), 2500);</script></body></html>"
    ), (200 if ok else 400)


@bp.get("/api/pubpod/instagram/callback")
def instagram_callback():
    from html import escape
    if request.args.get("error"):
        return _popup_page("No se conectó Instagram",
                           "Cancelaste el permiso o Instagram lo rechazó. Puedes cerrar esta ventana.", False)
    try:
        st = _state.loads(request.args.get("state") or "", max_age=900)
    except (BadSignature, SignatureExpired):
        return _popup_page("El enlace venció", "Vuelve a pulsar «Conectar Instagram».", False)
    cfg = _ig_config()
    code = (request.args.get("code") or "").removesuffix("#_")
    if not cfg or not code or st.get("net", "instagram") != "instagram":
        return _popup_page("Instagram no está disponible", "Inténtalo más tarde.", False)
    try:
        r = requests.post("https://api.instagram.com/oauth/access_token", data={
            "client_id": cfg["app_id"], "client_secret": cfg["app_secret"],
            "grant_type": "authorization_code", "redirect_uri": _ig_redirect_uri(),
            "code": code}, timeout=30)
        data = r.json()
        if isinstance(data.get("data"), list) and data["data"]:
            data = data["data"][0]
        short = data.get("access_token")
        if not short:
            raise RuntimeError(data.get("error_message") or "sin token")
        r = requests.get("https://graph.instagram.com/access_token", params={
            "grant_type": "ig_exchange_token", "client_secret": cfg["app_secret"],
            "access_token": short}, timeout=30)
        long_data = r.json()
        token = long_data.get("access_token") or short
        expires_at = _now() + int(long_data.get("expires_in") or 3600)
        r = requests.get(f"{IG_GRAPH}/me", params={
            "fields": "user_id,username,account_type", "access_token": token}, timeout=30)
        me = r.json()
        if not me.get("user_id"):
            raise RuntimeError((me.get("error") or {}).get("message") or "sin cuenta")
    except (requests.RequestException, ValueError, RuntimeError) as e:
        return _popup_page("No se pudo conectar Instagram", escape(str(e)[:200]), False)
    _save_account(st["slug"], "instagram", me["user_id"], me.get("username"),
                  token, expires_at, st.get("user"))
    return _popup_page(f"Instagram conectado: @{escape(me.get('username') or '')}",
                       "Puedes cerrar esta ventana y volver a thePod.", True)


# ---------------------------------------------------------------------------
# Meta: deauthorize and data deletion request (required for app review)
# ---------------------------------------------------------------------------

def _parse_signed_request(signed: str, secret: str):
    """Validate Meta's signed_request (HMAC-SHA256 with the app secret)."""
    import base64
    import hashlib
    import hmac

    def b64(x):
        return base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
    try:
        sig, payload = signed.split(".", 1)
        expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(b64(sig), expected):
            return None
        return json.loads(b64(payload))
    except (ValueError, TypeError):
        return None


def _forget_instagram_user(ig_user_id: str) -> int:
    """Delete that Instagram account's connection in all podcasts and cancel anything pending."""
    removed = 0
    for d in PODCASTS_DIR.glob("*/"):
        if not (d / "proyecto.sqlite").exists():
            continue
        try:
            conn = _db(d.name)
        except Exception:  # noqa: BLE001
            continue
        try:
            cur = conn.execute("DELETE FROM pub_accounts WHERE platform='instagram' AND account_id=?",
                               (str(ig_user_id),))
            if cur.rowcount:
                removed += cur.rowcount
                conn.execute("UPDATE pub_posts SET status='cancelled', updated_at=datetime('now') "
                             "WHERE platform='instagram' AND status IN ('scheduled','error')")
            conn.commit()
        finally:
            conn.close()
        if removed:
            _cleanup_media(d.name)
    return removed


def _meta_user_from_request():
    cfg = _ig_config()
    data = _parse_signed_request(request.form.get("signed_request") or "", cfg["app_secret"]) if cfg else None
    return (data or {}).get("user_id")


@bp.post("/api/pubpod/instagram/deauthorize")
def instagram_deauthorize():
    """Meta notifies that the person revoked thePod's permission."""
    uid = _meta_user_from_request()
    if not uid:
        return jsonify({"error": "solicitud inválida"}), 400
    _forget_instagram_user(uid)
    return jsonify({"ok": True})


@bp.post("/api/pubpod/instagram/data-deletion")
def instagram_data_deletion():
    """Meta asks to delete that person's data. Responds with a link to check the status."""
    uid = _meta_user_from_request()
    if not uid:
        return jsonify({"error": "solicitud inválida"}), 400
    _forget_instagram_user(uid)
    code = uuid.uuid4().hex[:12]
    base = (load_shared_config().get("prepod_url") or "").rstrip("/")
    return jsonify({"url": f"{base}/pub/borrado?codigo={code}", "confirmation_code": code})


@bp.get("/pub/borrado")
def deletion_status():
    from html import escape
    code = escape((request.args.get("codigo") or "")[:20])
    return (
        "<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'></head>"
        "<body style='font-family:system-ui;max-width:560px;margin:60px auto;padding:0 16px;line-height:1.5'>"
        "<h2>Tus datos de Instagram fueron borrados de thePod</h2>"
        "<p>Borramos el permiso para publicar en tu cuenta y cancelamos las publicaciones pendientes. "
        "Los reels ya publicados siguen en Instagram: bórralos desde la app si quieres.</p>"
        f"<p style='color:#666'>Código de confirmación: <code>{code}</code></p>"
        "<p>¿Dudas? Escríbenos a <a href='mailto:thepod@castmedia.space'>thepod@castmedia.space</a>.</p>"
        "</body></html>"
    )


@bp.get("/api/pubpod/podcasts/<slug>/prefs")
@require_auth
def get_prefs(slug):
    """Text always appended at the end for each target (hashtags, signature)."""
    denied = _access_error(slug)
    if denied:
        return denied
    conn = _db(slug)
    try:
        rows = conn.execute("SELECT platform, signature FROM pub_prefs").fetchall()
    finally:
        conn.close()
    return jsonify({"signatures": {r["platform"]: r["signature"] for r in rows}})


@bp.post("/api/pubpod/podcasts/<slug>/prefs")
@require_auth
def set_prefs(slug):
    denied = _access_error(slug)
    if denied:
        return denied
    data = request.get_json(silent=True) or {}
    sigs = data.get("signatures")
    if not isinstance(sigs, dict):
        return jsonify({"error": "signatures requerido"}), 400
    conn = _db(slug)
    try:
        for net, text in sigs.items():
            if net not in NETWORKS or not isinstance(text, str):
                continue
            conn.execute("INSERT INTO pub_prefs (platform, signature) VALUES (?, ?) "
                         "ON CONFLICT(platform) DO UPDATE SET signature=excluded.signature",
                         (net, text.strip()[:1000]))
        conn.commit()
        rows = conn.execute("SELECT platform, signature FROM pub_prefs").fetchall()
    finally:
        conn.close()
    return jsonify({"signatures": {r["platform"]: r["signature"] for r in rows}})


@bp.post("/api/pubpod/podcasts/<slug>/accounts/<net>/disconnect")
@require_auth
def disconnect(slug, net):
    denied = _access_error(slug)
    if denied:
        return denied
    if net == "youtube":
        from youtube_publish import _delete_tokens
        _delete_tokens(slug)
        return jsonify({"ok": True})
    if net not in ("instagram", "tiktok"):
        return jsonify({"error": "red desconocida"}), 400
    conn = _db(slug)
    try:
        conn.execute("DELETE FROM pub_accounts WHERE platform=?", (net,))
        conn.commit()
    finally:
        conn.close()
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# TikTok: connection (Login Kit) — the reel lands in the user's inbox
# ---------------------------------------------------------------------------

def _tt_config():
    cfg = (load_shared_config().get("tiktok") or {})
    if not cfg.get("client_key") or not cfg.get("client_secret"):
        return None
    return cfg


def _tt_redirect_uri():
    base = (load_shared_config().get("prepod_url") or "").rstrip("/")
    return f"{base}/api/pubpod/tiktok/callback"


@bp.get("/api/pubpod/tiktok/auth-url")
@require_auth
def tiktok_auth_url():
    slug = (request.args.get("slug") or "").strip()
    denied = _access_error(slug)
    if denied:
        return denied
    cfg = _tt_config()
    if not cfg:
        return jsonify({"error": "TikTok todavía no está habilitado en thePod"}), 503
    from urllib.parse import urlencode
    url = "https://www.tiktok.com/v2/auth/authorize/?" + urlencode({
        "client_key": cfg["client_key"],
        "scope": TT_SCOPES,
        "response_type": "code",
        "redirect_uri": _tt_redirect_uri(),
        "state": _state.dumps({"slug": slug, "user": session.get("username"), "net": "tiktok"}),
    })
    return jsonify({"auth_url": url})


def _tt_save_tokens(slug, data, user, username=None):
    _save_account(slug, "tiktok", data["open_id"], username, data["access_token"],
                  _now() + int(data.get("expires_in") or 86400), user,
                  refresh_token=data.get("refresh_token"),
                  refresh_expires_at=_now() + int(data.get("refresh_expires_in") or 31536000))


@bp.get("/api/pubpod/tiktok/callback")
def tiktok_callback():
    from html import escape
    if request.args.get("error"):
        return _popup_page("No se conectó TikTok",
                           "Cancelaste el permiso o TikTok lo rechazó. Puedes cerrar esta ventana.", False)
    try:
        st = _state.loads(request.args.get("state") or "", max_age=900)
    except (BadSignature, SignatureExpired):
        return _popup_page("El enlace venció", "Vuelve a pulsar «Conectar TikTok».", False)
    cfg = _tt_config()
    code = request.args.get("code") or ""
    if not cfg or not code or st.get("net") != "tiktok":
        return _popup_page("TikTok no está disponible", "Inténtalo más tarde.", False)
    try:
        r = requests.post(f"{TT_API}/oauth/token/", data={
            "client_key": cfg["client_key"], "client_secret": cfg["client_secret"],
            "code": code, "grant_type": "authorization_code",
            "redirect_uri": _tt_redirect_uri()}, timeout=30)
        data = r.json()
        if not data.get("access_token"):
            raise RuntimeError(data.get("error_description") or data.get("error") or "sin token")
        name = None
        try:
            r = requests.get(f"{TT_API}/user/info/", params={"fields": "open_id,display_name"},
                             headers={"Authorization": f"Bearer {data['access_token']}"}, timeout=30)
            name = ((r.json().get("data") or {}).get("user") or {}).get("display_name")
        except (requests.RequestException, ValueError):
            pass
    except (requests.RequestException, ValueError, RuntimeError) as e:
        return _popup_page("No se pudo conectar TikTok", escape(str(e)[:200]), False)
    _tt_save_tokens(st["slug"], data, st.get("user"), name)
    return _popup_page(f"TikTok conectado{': ' + escape(name) if name else ''}",
                       "Puedes cerrar esta ventana y volver a thePod.", True)


def _tt_token(slug):
    """Current TikTok token (lasts 24 h); refreshes it with the refresh token (lasts one year)."""
    acc = _get_account(slug, "tiktok")
    if not acc:
        return None
    if (acc.get("expires_at") or 0) - _now() > 600:
        return acc["access_token"]
    cfg = _tt_config()
    if not cfg or not acc.get("refresh_token"):
        return None
    try:
        r = requests.post(f"{TT_API}/oauth/token/", data={
            "client_key": cfg["client_key"], "client_secret": cfg["client_secret"],
            "grant_type": "refresh_token", "refresh_token": acc["refresh_token"]}, timeout=30)
        data = r.json()
    except (requests.RequestException, ValueError):
        return None
    if not data.get("access_token"):
        return None
    data.setdefault("open_id", acc["account_id"])
    _tt_save_tokens(slug, data, acc.get("connected_by"), acc.get("username"))
    return data["access_token"]


# ---------------------------------------------------------------------------
# Create posts
# ---------------------------------------------------------------------------

def _validate_targets(raw):
    if not isinstance(raw, list) or not raw:
        raise ValueError("elige al menos una red")
    out, seen = [], set()
    for t in raw:
        if not isinstance(t, dict):
            raise ValueError("red inválida")
        net = (t.get("platform") or "").strip()
        if net not in NETWORKS:
            raise ValueError(f"red no disponible: {net or '—'}")
        if net in seen:
            continue
        seen.add(net)
        caption = str(t.get("caption") or "")
        if len(caption) > CAPTION_MAX[net]:
            raise ValueError(f"el texto para {net} es demasiado largo")
        out.append({"platform": net, "caption": caption})
    return out


def _create_posts(slug, src_path: Path, move: bool, payload: dict, user: str):
    """Validate, store the video and create one post per network. Returns (posts, None) or (None, error)."""
    title = (payload.get("title") or "").strip()[:200]
    if not title:
        return None, "falta el título del reel"
    try:
        targets = _validate_targets(payload.get("targets"))
        when = _parse_when(payload.get("scheduled_at"))
    except ValueError as e:
        return None, str(e)
    if when < _now() - 60:
        return None, "la fecha ya pasó"
    episode_id = payload.get("episode_id")
    if episode_id is not None and not isinstance(episode_id, int):
        return None, "episodio inválido"
    kind = payload.get("kind") or "reel"
    if kind not in FOR_KIND:
        return None, "tipo inválido"
    wrong = [t["platform"] for t in targets if t["platform"] not in FOR_KIND[kind]]
    if wrong:
        return None, ("el episodio completo va a YouTube, Spotify, Apple Podcasts y la portada de Instagram"
                      if kind == "episode" else "un reel va a Reels, Shorts y TikTok")
    if any(t["platform"] == "feed" for t in targets) and episode_id is None:
        return None, "para Spotify y Apple Podcasts el episodio tiene que estar vinculado en prePod"

    missing = []
    ig = any(t["platform"] in ("instagram", "instagram_image") for t in targets)
    if ig and not _get_account(slug, "instagram"):
        missing.append("Instagram")
    if any(t["platform"] == "youtube" for t in targets):
        from youtube_publish import _get_stored_tokens
        if not _get_stored_tokens(slug):
            missing.append("YouTube")
    if any(t["platform"] == "tiktok" for t in targets) and not _get_account(slug, "tiktok"):
        missing.append("TikTok")
    if any(t["platform"] == "feed" for t in targets) and not _feed_ready():
        missing.append("el alojamiento del feed")
    if missing:
        return None, "conecta primero: " + ", ".join(missing)

    ext = (payload.get("_ext") or Path(src_path).suffix[1:] or "mp4").lower()
    if ext not in MEDIA_EXT:
        return None, "ese tipo de archivo no se puede publicar"
    token = uuid.uuid4().hex
    dest = _media_dir(slug) / f"{token}.{ext}"
    if move:
        shutil.move(str(src_path), dest)
    else:
        shutil.copyfile(src_path, dest)

    conn = _db(slug)
    try:
        sigs = {r["platform"]: r["signature"] for r in conn.execute("SELECT platform, signature FROM pub_prefs")}
        for t in targets:
            sig = (sigs.get(t["platform"]) or "").strip()
            if sig and sig not in t["caption"]:
                t["caption"] = (t["caption"].rstrip() + "\n\n" + sig).strip()[:CAPTION_MAX[t["platform"]]]
        ids = []
        for t in targets:
            cur = conn.execute(
                """INSERT INTO pub_posts (episode_id, title, platform, caption, media_token,
                                          scheduled_at, created_by, kind) VALUES (?,?,?,?,?,?,?,?)""",
                (episode_id, title, t["platform"], t["caption"], token, when, user, kind))
            ids.append(cur.lastrowid)
        conn.commit()
        rows = conn.execute(
            f"SELECT * FROM pub_posts WHERE id IN ({','.join('?' * len(ids))})", ids).fetchall()
    finally:
        conn.close()
    _wake.set()
    return [_post_json(r) for r in rows], None


@bp.post("/api/pubpod/reels")
@require_auth
def create_from_upload():
    """From the Mac app: the video was already uploaded via /api/mac/uploads."""
    data = request.get_json(silent=True) or {}
    slug = (data.get("slug") or "").strip()
    denied = _access_error(slug)
    if denied:
        return denied
    upload_id = (data.get("upload_id") or "").strip()
    import mac_publish as mp
    if not mp._valid_upload_id(upload_id):
        return jsonify({"error": "upload_id inválido"}), 400
    with mp._upload_lock(upload_id):
        path, meta = mp._resolve_upload(upload_id)
        if not path:
            return jsonify({"error": "el video no terminó de subir"}), 404
        if meta.get("claimed"):
            return jsonify({"error": "ese video ya se está publicando"}), 409
        meta["claimed"] = True
        mp._write_meta(upload_id, meta)
    data["_ext"] = Path(meta.get("filename") or "").suffix[1:].lower() or "mp4"
    posts, err = _create_posts(slug, path, True, data, session.get("username"))
    if err:
        mp._release_upload_claim(upload_id)
        return jsonify({"error": err}), 400
    mp._delete_upload(upload_id)
    return jsonify({"posts": posts}), 201


def _post_json(r):
    d = dict(r)
    return {
        "id": d["id"], "episode_id": d["episode_id"], "title": d["title"],
        "platform": d["platform"], "caption": d["caption"], "status": d["status"],
        "scheduled_at": _iso(d["scheduled_at"]), "result_url": d["result_url"],
        "error": d["error"], "created_at": d["created_at"], "kind": d.get("kind") or "reel",
    }


@bp.get("/api/pubpod/podcasts/<slug>/posts")
@require_auth
def list_posts(slug):
    denied = _access_error(slug)
    if denied:
        return denied
    conn = _db(slug)
    try:
        rows = conn.execute(
            "SELECT * FROM pub_posts ORDER BY scheduled_at DESC, id DESC LIMIT 200").fetchall()
    finally:
        conn.close()
    return jsonify({"posts": [_post_json(r) for r in rows]})


def _set_status(slug, post_id, frm, to, **extra):
    conn = _db(slug)
    try:
        sets = ", ".join([f"{k}=?" for k in extra] + ["status=?", "updated_at=datetime('now')"])
        cur = conn.execute(
            f"UPDATE pub_posts SET {sets} WHERE id=? AND status IN ({','.join('?' * len(frm))})",
            (*extra.values(), to, post_id, *frm))
        conn.commit()
        return cur.rowcount == 1
    finally:
        conn.close()


@bp.post("/api/pubpod/podcasts/<slug>/posts/<int:post_id>/cancel")
@require_auth
def cancel_post(slug, post_id):
    denied = _access_error(slug)
    if denied:
        return denied
    if not _set_status(slug, post_id, ("scheduled",), "cancelled"):
        return jsonify({"error": "solo se puede cancelar lo que aún no salió"}), 409
    _cleanup_media(slug)
    return jsonify({"ok": True})


@bp.post("/api/pubpod/podcasts/<slug>/posts/<int:post_id>/retry")
@require_auth
def retry_post(slug, post_id):
    denied = _access_error(slug)
    if denied:
        return denied
    conn = _db(slug)
    try:
        row = conn.execute("SELECT media_token FROM pub_posts WHERE id=?", (post_id,)).fetchone()
    finally:
        conn.close()
    if not row or not _media_path(slug, row["media_token"]).exists():
        return jsonify({"error": "el video ya no está disponible; súbelo de nuevo"}), 410
    if not _set_status(slug, post_id, ("error",), "scheduled", scheduled_at=_now(), error=None):
        return jsonify({"error": "solo se reintenta lo que falló"}), 409
    _wake.set()
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Temporary public video (Instagram downloads it from here)
# ---------------------------------------------------------------------------

@bp.get("/pub/m/<slug>/<name>")
def public_media(slug, name):
    token, _, ext = name.partition(".")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", slug) or not _TOKEN_RE.match(token) or ext.lower() not in MEDIA_EXT:
        abort(404)
    path = _media_dir(slug) / f"{token}.{ext}"
    if not path.is_file():
        abort(404)
    conn = _db(slug)
    try:
        live = conn.execute(
            "SELECT 1 FROM pub_posts WHERE media_token=? AND status IN ('scheduled','publishing','error')",
            (token,)).fetchone()
    finally:
        conn.close()
    if not live:
        abort(404)
    return send_file(path, mimetype=MIME[ext.lower()], conditional=True, max_age=0)


def _cleanup_media(slug):
    """Delete videos no pending post needs anymore, or older than 7 days."""
    d = PODCASTS_DIR / slug / "pubpod"
    if not d.is_dir():
        return
    conn = _db(slug)
    try:
        pending = {r["media_token"] for r in conn.execute(
            "SELECT DISTINCT media_token FROM pub_posts WHERE status IN ('scheduled','publishing','error')")}
    finally:
        conn.close()
    for f in d.glob("*.*"):
        if f.suffix[1:].lower() not in MEDIA_EXT:
            continue
        if f.name.startswith("_in_"):
            if _now() - f.stat().st_mtime > 3600:
                f.unlink(missing_ok=True)
            continue
        if f.stem not in pending or _now() - f.stat().st_mtime > MEDIA_KEEP_SECONDS:
            f.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Publishers
# ---------------------------------------------------------------------------

class PublishError(Exception):
    pass


def _ig_error(resp):
    try:
        e = resp.json().get("error") or {}
        return e.get("error_user_msg") or e.get("message") or resp.text[:200]
    except ValueError:
        return resp.text[:200]


def publish_instagram(slug, post, media_url, image=False):
    token, ig_id = _ig_token(slug)
    if not token:
        raise PublishError("Instagram no está conectado")
    data = ({"image_url": media_url, "caption": post["caption"], "access_token": token} if image else
            {"media_type": "REELS", "video_url": media_url, "caption": post["caption"],
             "share_to_feed": "true", "access_token": token})
    r = requests.post(f"{IG_GRAPH}/{ig_id}/media", data=data, timeout=60)
    if not r.ok:
        raise PublishError(_ig_error(r))
    container = r.json()["id"]
    deadline = _now() + 15 * 60
    while True:
        time.sleep(15)
        r = requests.get(f"{IG_GRAPH}/{container}",
                         params={"fields": "status_code,status", "access_token": token}, timeout=30)
        st = (r.json() or {}).get("status_code") if r.ok else None
        if st == "FINISHED":
            break
        if st in ("ERROR", "EXPIRED"):
            raise PublishError("Instagram no pudo procesar el video (revisa que sea vertical y dure menos de 15 minutos)")
        if _now() > deadline:
            raise PublishError("Instagram tardó demasiado en procesar el video")
    r = requests.post(f"{IG_GRAPH}/{ig_id}/media_publish",
                      data={"creation_id": container, "access_token": token}, timeout=60)
    if not r.ok:
        raise PublishError(_ig_error(r))
    media_id = r.json()["id"]
    link = None
    try:
        r = requests.get(f"{IG_GRAPH}/{media_id}",
                         params={"fields": "permalink", "access_token": token}, timeout=30)
        link = r.json().get("permalink")
    except (requests.RequestException, ValueError):
        pass
    return "published", link or "https://www.instagram.com/"


def publish_youtube(slug, post, media_path):
    import youtube_publish
    title = post["title"][:100]
    if post.get("kind", "reel") == "reel" and "#shorts" not in title.lower():
        title = (title[:91] + " #Shorts")
    res = youtube_publish._upload_video(slug, media_path, title, post["caption"],
                                        privacy="public", category="22")
    if not res.get("ok"):
        raise PublishError(res.get("error") or "YouTube rechazó el video")
    # Until Google approves the app, YouTube keeps the video private.
    status = "published"
    try:
        from googleapiclient.discovery import build
        tokens = youtube_publish._get_stored_tokens(slug)
        creds = youtube_publish._build_credentials(tokens, youtube_publish._get_youtube_config())
        yt = build("youtube", "v3", credentials=creds)
        items = yt.videos().list(part="status", id=res["video_id"]).execute().get("items") or []
        if items and items[0]["status"].get("privacyStatus") != "public":
            status = "private"
    except Exception:
        pass
    if post.get("kind") == "episode":
        return status, f"https://www.youtube.com/watch?v={res['video_id']}"
    return status, f"https://youtube.com/shorts/{res['video_id']}"


TT_CHUNK = 10 * 1024 * 1024
TT_ERRORS = {
    "spam_risk_too_many_pending_share": "TikTok permite como máximo 5 videos esperando en tu bandeja por día. Publica o descarta los que tienes y reintenta.",
    "access_token_invalid": "La conexión con TikTok venció. Vuelve a conectar TikTok en Redes.",
    "scope_not_authorized": "Falta el permiso para subir videos. Vuelve a conectar TikTok en Redes.",
    "rate_limit_exceeded": "TikTok pidió esperar un momento. Reintenta en unos minutos.",
}


def _tt_fail(data, fallback):
    err = (data or {}).get("error") or {}
    code = err.get("code") if isinstance(err, dict) else None
    return TT_ERRORS.get(code) or (err.get("message") if isinstance(err, dict) else None) or fallback


def publish_tiktok(slug, post, media_path):
    """Send the reel to the user's TikTok inbox; they finish publishing it in the app.
    (Direct posting requires TikTok's audit.)"""
    token = _tt_token(slug)
    if not token:
        raise PublishError("La conexión con TikTok venció. Vuelve a conectar TikTok en Redes.")
    size = Path(media_path).stat().st_size
    # TikTok rules: 5 to 64 MB chunks; a small video goes whole; the last chunk absorbs the remainder
    if size <= 64 * 1024 * 1024:
        chunk, count = size, 1
    else:
        chunk, count = TT_CHUNK, size // TT_CHUNK
    auth = {"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=UTF-8"}
    r = requests.post(f"{TT_API}/post/publish/inbox/video/init/", headers=auth, json={
        "source_info": {"source": "FILE_UPLOAD", "video_size": size,
                        "chunk_size": chunk, "total_chunk_count": count}}, timeout=60)
    data = r.json() if r.content else {}
    if not r.ok or not (data.get("data") or {}).get("upload_url"):
        raise PublishError(_tt_fail(data, "TikTok no aceptó el video"))
    publish_id = data["data"]["publish_id"]
    upload_url = data["data"]["upload_url"]
    with open(media_path, "rb") as f:
        for i in range(count):
            start = i * chunk
            end = size - 1 if i == count - 1 else start + chunk - 1
            f.seek(start)
            body = f.read(end - start + 1)
            r = requests.put(upload_url, data=body, timeout=300, headers={
                "Content-Type": "video/mp4", "Content-Length": str(len(body)),
                "Content-Range": f"bytes {start}-{end}/{size}"})
            if r.status_code not in (200, 201, 206):
                raise PublishError("Se cortó la subida a TikTok. Reintenta.")
    deadline = _now() + 10 * 60
    while _now() < deadline:
        time.sleep(10)
        r = requests.post(f"{TT_API}/post/publish/status/fetch/", headers=auth,
                          json={"publish_id": publish_id}, timeout=30)
        d = (r.json() or {}).get("data") or {} if r.content else {}
        st = d.get("status")
        if st == "SEND_TO_USER_INBOX":
            return "inbox", None
        if st == "PUBLISH_COMPLETE":
            return "published", "https://www.tiktok.com/"
        if st == "FAILED":
            raise PublishError(f"TikTok no pudo procesar el video ({d.get('fail_reason') or 'sin motivo'})")
    # Still processing: most likely it will reach the inbox anyway
    return "inbox", None


def _feed_ready() -> bool:
    """Spotify and Apple Podcasts read the feed: audio hosting must be configured."""
    return bool((load_shared_config().get("hosting") or {}).get("host"))


def publish_feed(slug, post, media_path):
    """The audio to the podcast feed: Spotify and Apple Podcasts pick it up from there on their own."""
    if not post.get("episode_id"):
        raise PublishError("el episodio no está vinculado en prePod")
    if (post.get("caption") or "").strip():
        conn = get_db(slug)
        try:
            conn.execute("UPDATE episodes SET description=?, updated_at=datetime('now') WHERE id=?",
                         (post["caption"].strip(), post["episode_id"]))
            conn.commit()
        finally:
            conn.close()
    from episodes import upload_episode_media
    res = upload_episode_media(slug, post["episode_id"], media_path)
    if not res.get("ok"):
        raise PublishError(res.get("error") or "no se pudo poner el audio en el feed")
    return "published", res.get("media_url")


def _publish_one(slug, post):
    path = _media_path(slug, post["media_token"])
    if not path.is_file():
        raise PublishError("el archivo ya no está disponible; súbelo de nuevo")
    if post["platform"] == "instagram":
        return publish_instagram(slug, post, _media_url(slug, path))
    if post["platform"] == "instagram_image":
        return publish_instagram(slug, post, _media_url(slug, path), image=True)
    if post["platform"] == "feed":
        return publish_feed(slug, post, path)
    if post["platform"] == "youtube":
        return publish_youtube(slug, post, path)
    if post["platform"] == "tiktok":
        return publish_tiktok(slug, post, path)
    raise PublishError("red no disponible")


# ---------------------------------------------------------------------------
# Scheduler (one thread in the single gunicorn worker)
# ---------------------------------------------------------------------------

_wake = threading.Event()
_started = False
_start_lock = threading.Lock()


def _claim_due(slug):
    conn = _db(slug)
    try:
        rows = conn.execute(
            "SELECT * FROM pub_posts WHERE status='scheduled' AND scheduled_at<=? ORDER BY scheduled_at",
            (_now(),)).fetchall()
        claimed = []
        for r in rows:
            cur = conn.execute(
                "UPDATE pub_posts SET status='publishing', attempts=attempts+1, updated_at=datetime('now') "
                "WHERE id=? AND status='scheduled'", (r["id"],))
            if cur.rowcount == 1:
                claimed.append(dict(r))
        conn.commit()
        return claimed
    finally:
        conn.close()


_NET_LABEL = {"youtube": "YouTube", "instagram": "Instagram", "instagram_image": "Instagram", "tiktok": "TikTok", "feed": "el feed (Spotify/Apple)"}


def _notify_post(slug, post, status, url=None, error=None):
    """Phone notification to whoever scheduled it and to the owner/hosts: published, in review or failed."""
    try:
        conn = _db(slug)
        try:
            meta = conn.execute("SELECT name, owner_username, extra_hosts FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        finally:
            conn.close()
        from podcasts import _row_owner, _row_extra_hosts
        who = ([_row_owner(meta)] + _row_extra_hosts(meta)) if meta else []
        if post.get("created_by"):
            who.append(post["created_by"])
        net = _NET_LABEL.get(post["platform"], post["platform"])
        title = "pub · " + ((meta["name"] if meta and meta["name"] else slug))
        if status == "error":
            body = "No se pudo publicar «%s» en %s: %s" % (post["title"], net, (error or "")[:120])
        elif status in ("private", "inbox"):
            body = "«%s» quedó en %s pero sin publicar todavía (%s)." % (post["title"], net, "privado" if status == "private" else "bandeja de entrada")
        else:
            body = "«%s» ya está en %s." % (post["title"], net)
        push_notify(who, title, body, url or "/pre/", tag="pub-" + str(post["id"]))
    except Exception:
        pass


def run_due(slug):
    """Publish a podcast's due posts. Returns how many posts it processed."""
    done = 0
    for post in _claim_due(slug):
        try:
            status, url = _publish_one(slug, post)
            _set_status(slug, post["id"], ("publishing",), status, result_url=url, error=None)
            _notify_post(slug, post, status, url=url)
        except PublishError as e:
            _set_status(slug, post["id"], ("publishing",), "error", error=str(e)[:300])
            _notify_post(slug, post, "error", error=str(e))
        except Exception as e:  # noqa: BLE001 — never leave a post stuck in "publishing"
            _set_status(slug, post["id"], ("publishing",), "error",
                        error=f"error inesperado: {str(e)[:200]}")
            _notify_post(slug, post, "error", error="error inesperado")
        done += 1
    _cleanup_media(slug)
    return done


def _recover_interrupted():
    """If the service restarted mid-publish, it is not retried automatically:
    it could be duplicated. It is marked as error so the user decides."""
    for d in PODCASTS_DIR.glob("*/"):
        if not (d / "pubpod").is_dir():
            continue
        conn = _db(d.name)
        try:
            conn.execute(
                "UPDATE pub_posts SET status='error', error=? WHERE status='publishing'",
                ("se interrumpió; revisa la red antes de reintentar",))
            conn.commit()
        finally:
            conn.close()


def _loop():
    _recover_interrupted()
    while True:
        _wake.wait(timeout=30)
        _wake.clear()
        for d in sorted(PODCASTS_DIR.glob("*/")):
            if (d / "pubpod").is_dir():
                try:
                    run_due(d.name)
                except Exception as e:  # noqa: BLE001
                    print(f"[pubpod] {d.name}: {e}", flush=True)


def start_scheduler():
    global _started
    if os.environ.get("PUBPOD_SCHEDULER", "1") == "0":
        return
    with _start_lock:
        if _started:
            return
        _started = True
    threading.Thread(target=_loop, daemon=True, name="pubpod-scheduler").start()
