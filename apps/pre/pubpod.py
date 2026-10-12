"""
pubPod — publicar y programar reels en las redes del podcast.

Primera versión: Instagram (API con inicio de sesión de Instagram) y YouTube
Shorts (reusa la conexión de YouTube que ya tiene prePod). TikTok y Facebook
se agregan cuando existan sus apps; cada red vive en su propio "publicador"
para pasar del modo limitado al completo red por red.

Endpoints (sesión de thePod):
    GET  /api/pubpod/networks                         redes disponibles en el servidor
    GET  /api/pubpod/podcasts/<slug>/accounts         cuentas conectadas
    GET  /api/pubpod/instagram/auth-url?slug=         URL para conectar Instagram
    GET  /api/pubpod/instagram/callback               vuelta de Instagram (pública)
    POST /api/pubpod/podcasts/<slug>/accounts/<net>/disconnect
    POST /api/pubpod/reels                            {slug, upload_id, title, targets, scheduled_at, episode_id}
                                                      (el video se sube antes por /api/mac/uploads, web y Mac)
    GET  /api/pubpod/podcasts/<slug>/posts
    POST /api/pubpod/podcasts/<slug>/posts/<id>/cancel
    POST /api/pubpod/podcasts/<slug>/posts/<id>/retry
    GET  /pub/m/<slug>/<token>.mp4                    video público temporal (Meta lo descarga)

Config en ~/.podpod/config.json:
    "instagram": {"app_id": "...", "app_secret": "..."}
La redirección es <prepod_url>/api/pubpod/instagram/callback.
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
from shared_config import load_shared_config

bp = Blueprint("pubpod", __name__)

IG_GRAPH = "https://graph.instagram.com/v23.0"
IG_SCOPES = "instagram_business_basic,instagram_business_content_publish"
NETWORKS = ("instagram", "youtube")
CAPTION_MAX = {"instagram": 2200, "youtube": 5000}
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
        CHECK(status IN ('scheduled','publishing','published','private','error','cancelled')),
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
# Base de datos y archivos
# ---------------------------------------------------------------------------

def _db(slug: str):
    conn = get_db(slug)
    conn.executescript(SCHEMA)
    return conn


def _media_dir(slug: str) -> Path:
    d = PODCASTS_DIR / slug / "pubpod"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _media_path(slug: str, token: str) -> Path:
    return _media_dir(slug) / f"{token}.mp4"


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
    """None/'' → ahora. ISO 8601 (con zona) → epoch. Error → ValueError."""
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
# Acceso por podcast (mismo criterio que mac_publish)
# ---------------------------------------------------------------------------

def _access_error(slug: str):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", slug or ""):
        return jsonify({"error": "podcast inválido"}), 400
    from mac_publish import _podcast_access_error
    return _podcast_access_error(slug)


# ---------------------------------------------------------------------------
# Instagram: conexión
# ---------------------------------------------------------------------------

def _ig_config():
    cfg = (load_shared_config().get("instagram") or {})
    if not cfg.get("app_id") or not cfg.get("app_secret"):
        return None
    return cfg


def _ig_redirect_uri():
    base = (load_shared_config().get("prepod_url") or "").rstrip("/")
    return f"{base}/api/pubpod/instagram/callback"


def _save_account(slug, platform, account_id, username, token, expires_at, user):
    conn = _db(slug)
    try:
        conn.execute(
            """INSERT INTO pub_accounts (platform, account_id, username, access_token, expires_at, connected_by)
               VALUES (?,?,?,?,?,?)
               ON CONFLICT(platform) DO UPDATE SET account_id=excluded.account_id,
                 username=excluded.username, access_token=excluded.access_token,
                 expires_at=excluded.expires_at, connected_by=excluded.connected_by,
                 connected_at=datetime('now')""",
            (platform, str(account_id), username, token, expires_at, user),
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
    """Token vigente de Instagram; lo renueva si vence en menos de 7 días."""
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
        "tiktok": False,
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
    if not cfg or not code:
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


@bp.post("/api/pubpod/podcasts/<slug>/accounts/<net>/disconnect")
@require_auth
def disconnect(slug, net):
    denied = _access_error(slug)
    if denied:
        return denied
    if net != "instagram":
        return jsonify({"error": "esa red se desconecta desde Distribución"}), 400
    conn = _db(slug)
    try:
        conn.execute("DELETE FROM pub_accounts WHERE platform=?", (net,))
        conn.commit()
    finally:
        conn.close()
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Crear publicaciones
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
    """Valida, guarda el video y crea una publicación por red. Devuelve (posts, None) o (None, error)."""
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

    missing = []
    ig = any(t["platform"] == "instagram" for t in targets)
    if ig and not _get_account(slug, "instagram"):
        missing.append("Instagram")
    if any(t["platform"] == "youtube" for t in targets):
        from youtube_publish import _get_stored_tokens
        if not _get_stored_tokens(slug):
            missing.append("YouTube")
    if missing:
        return None, "conecta primero: " + ", ".join(missing)

    token = uuid.uuid4().hex
    dest = _media_path(slug, token)
    if move:
        shutil.move(str(src_path), dest)
    else:
        shutil.copyfile(src_path, dest)

    conn = _db(slug)
    try:
        ids = []
        for t in targets:
            cur = conn.execute(
                """INSERT INTO pub_posts (episode_id, title, platform, caption, media_token,
                                          scheduled_at, created_by) VALUES (?,?,?,?,?,?,?)""",
                (episode_id, title, t["platform"], t["caption"], token, when, user))
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
    """Desde la app de Mac: el video ya se subió por /api/mac/uploads."""
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
        "error": d["error"], "created_at": d["created_at"],
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
# Video público temporal (Instagram lo descarga desde aquí)
# ---------------------------------------------------------------------------

@bp.get("/pub/m/<slug>/<token>.mp4")
def public_media(slug, token):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", slug) or not _TOKEN_RE.match(token):
        abort(404)
    path = _media_path(slug, token)
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
    return send_file(path, mimetype="video/mp4", conditional=True, max_age=0)


def _cleanup_media(slug):
    """Borra videos que ya no necesita ninguna publicación pendiente, o con más de 7 días."""
    d = PODCASTS_DIR / slug / "pubpod"
    if not d.is_dir():
        return
    conn = _db(slug)
    try:
        pending = {r["media_token"] for r in conn.execute(
            "SELECT DISTINCT media_token FROM pub_posts WHERE status IN ('scheduled','publishing','error')")}
    finally:
        conn.close()
    for f in d.glob("*.mp4"):
        if f.name.startswith("_in_"):
            if _now() - f.stat().st_mtime > 3600:
                f.unlink(missing_ok=True)
            continue
        if f.stem not in pending or _now() - f.stat().st_mtime > MEDIA_KEEP_SECONDS:
            f.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Publicadores
# ---------------------------------------------------------------------------

class PublishError(Exception):
    pass


def _ig_error(resp):
    try:
        e = resp.json().get("error") or {}
        return e.get("error_user_msg") or e.get("message") or resp.text[:200]
    except ValueError:
        return resp.text[:200]


def publish_instagram(slug, post, media_url):
    token, ig_id = _ig_token(slug)
    if not token:
        raise PublishError("Instagram no está conectado")
    r = requests.post(f"{IG_GRAPH}/{ig_id}/media", data={
        "media_type": "REELS", "video_url": media_url, "caption": post["caption"],
        "share_to_feed": "true", "access_token": token}, timeout=60)
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
    title = post["title"]
    if "#shorts" not in title.lower():
        title = (title[:91] + " #Shorts")
    res = youtube_publish._upload_video(slug, media_path, title, post["caption"],
                                        privacy="public", category="22")
    if not res.get("ok"):
        raise PublishError(res.get("error") or "YouTube rechazó el video")
    # Mientras Google no apruebe la app, YouTube deja el video en privado.
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
    return status, f"https://youtube.com/shorts/{res['video_id']}"


def _publish_one(slug, post):
    path = _media_path(slug, post["media_token"])
    if not path.is_file():
        raise PublishError("el video ya no está disponible; súbelo de nuevo")
    if post["platform"] == "instagram":
        base = (load_shared_config().get("prepod_url") or "").rstrip("/")
        return publish_instagram(slug, post, f"{base}/pub/m/{slug}/{post['media_token']}.mp4")
    if post["platform"] == "youtube":
        return publish_youtube(slug, post, path)
    raise PublishError("red no disponible")


# ---------------------------------------------------------------------------
# Programador (un hilo en el único worker de gunicorn)
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


def run_due(slug):
    """Publica lo vencido de un podcast. Devuelve cuántas publicaciones procesó."""
    done = 0
    for post in _claim_due(slug):
        try:
            status, url = _publish_one(slug, post)
            _set_status(slug, post["id"], ("publishing",), status, result_url=url, error=None)
        except PublishError as e:
            _set_status(slug, post["id"], ("publishing",), "error", error=str(e)[:300])
        except Exception as e:  # noqa: BLE001 — nunca dejar un post colgado en "publishing"
            _set_status(slug, post["id"], ("publishing",), "error",
                        error=f"error inesperado: {str(e)[:200]}")
        done += 1
    _cleanup_media(slug)
    return done


def _recover_interrupted():
    """Si el servicio se reinició a mitad de una publicación, no se reintenta solo:
    podría duplicarse. Se marca como error para que el usuario decida."""
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
