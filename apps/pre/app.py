import mimetypes
import os
import re
from datetime import timedelta
from pathlib import Path

from flask import Flask, Response, abort, render_template

import auth
import branding as branding_bp
import calendar_export as calendar_bp
import episodes as episodes_bp
import integrations as integrations_bp
import landing as landing_bp
import podcasts
import rsvp as rsvp_bp
import sounds as sounds_bp
import sponsors_api
import templates_api
import users_admin
import signup as signup_bp
import distribution as distribution_bp
import youtube_publish as youtube_bp
import mac_publish
import pubpod
import reminders
from auth import require_auth
from config import AVAILABLE_FONTS, PODCASTS_DIR, SECRET_KEY


def _serve_with_range(full_path: Path, request):
    if not full_path.is_file():
        abort(404)
    file_size = full_path.stat().st_size
    content_type, _ = mimetypes.guess_type(str(full_path))
    content_type = content_type or "application/octet-stream"

    range_header = request.headers.get("Range")
    if not range_header:
        def full():
            with open(full_path, "rb") as fh:
                while True:
                    chunk = fh.read(64 * 1024)
                    if not chunk:
                        break
                    yield chunk
        resp = Response(full(), mimetype=content_type)
        resp.headers["Content-Length"] = str(file_size)
        resp.headers["Accept-Ranges"] = "bytes"
        return resp

    m = re.match(r"bytes=(\d*)-(\d*)", range_header.strip())
    if not m:
        abort(416)
    start_s, end_s = m.group(1), m.group(2)
    if start_s == "" and end_s == "":
        abort(416)
    if start_s == "":
        length = int(end_s)
        start = max(0, file_size - length)
        end = file_size - 1
    else:
        start = int(start_s)
        end = int(end_s) if end_s else file_size - 1
    end = min(end, file_size - 1)
    if start > end or start >= file_size:
        resp = Response(status=416)
        resp.headers["Content-Range"] = f"bytes */{file_size}"
        return resp

    length = end - start + 1

    def stream():
        with open(full_path, "rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    resp = Response(stream(), status=206, mimetype=content_type)
    resp.headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
    resp.headers["Accept-Ranges"] = "bytes"
    resp.headers["Content-Length"] = str(length)
    return resp


def create_app():
    from config import SESSION_COOKIE_DOMAIN
    from werkzeug.middleware.proxy_fix import ProxyFix

    app = Flask(__name__, static_folder="static", template_folder="templates")
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    app.config["SECRET_KEY"] = SECRET_KEY
    app.config["MAX_CONTENT_LENGTH"] = 32 * 1024 * 1024  # 32 MB for image uploads
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_NAME"] = "podpod_session"
    if SESSION_COOKIE_DOMAIN:
        app.config["SESSION_COOKIE_DOMAIN"] = SESSION_COOKIE_DOMAIN
    app.permanent_session_lifetime = timedelta(days=7)

    app.register_blueprint(auth.bp)
    app.register_blueprint(podcasts.bp)
    app.register_blueprint(branding_bp.bp)
    app.register_blueprint(episodes_bp.bp)
    app.register_blueprint(landing_bp.bp)
    app.register_blueprint(integrations_bp.bp)
    app.register_blueprint(sounds_bp.bp)
    app.register_blueprint(calendar_bp.bp)
    app.register_blueprint(templates_api.bp)
    app.register_blueprint(sponsors_api.bp)
    app.register_blueprint(rsvp_bp.bp)
    app.register_blueprint(users_admin.bp)
    app.register_blueprint(signup_bp.bp)
    app.register_blueprint(distribution_bp.bp)
    app.register_blueprint(youtube_bp.bp)
    app.register_blueprint(mac_publish.bp)
    app.register_blueprint(pubpod.bp)
    pubpod.start_scheduler()
    reminders.start()

    PODCASTS_DIR.mkdir(parents=True, exist_ok=True)

    # Per-podcast access guard: anything under /api/podcasts/<slug>/... or
    # /media/podcasts/<slug>/... requires the current user to have access to
    # that podcast (owner, extra_host, or admin with see_all).
    import re as _re
    from flask import abort, request as _req, session as _sess, jsonify as _json
    _SLUG_RE = _re.compile(r"^/(?:api|media)/podcasts/([A-Za-z0-9_-]+)(?:/|$)")

    @app.before_request
    def _enforce_podcast_access():
        path = _req.path or ""
        # Allow the root podcasts list and create endpoint (those filter inside).
        if path in ("/api/podcasts", "/api/podcasts/"):
            return None
        m = _SLUG_RE.match(path)
        if not m:
            return None
        slug = m.group(1)
        # Skip if not logged in — let the per-endpoint require_auth handle 401.
        username = _sess.get("username")
        if not username:
            return None
        # Admin sees everything.
        from config import policy_for as _pol
        if _pol(username).get("see_all"):
            return None
        from db import get_db as _gdb
        if not (PODCASTS_DIR / slug).exists():
            return None  # let the endpoint return its own 404
        try:
            _db = _gdb(slug)
            row = _db.execute("SELECT owner_username, extra_hosts FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
            _db.close()
        except Exception:
            return None
        if not row:
            return None
        owner = row["owner_username"] or "admin"
        extras = []
        if row["extra_hosts"]:
            try:
                import json as _j
                v = _j.loads(row["extra_hosts"])
                if isinstance(v, list):
                    extras = [str(x) for x in v]
            except (TypeError, ValueError):
                pass
        if username != owner and username not in extras:
            return _json({"error": "no autorizado para este podcast"}), 403
        return None

    @app.get("/api/config/fonts")
    @require_auth
    def list_fonts():
        return {"fonts": AVAILABLE_FONTS}

    @app.get("/api/config/apps")
    def list_apps():
        from shared_config import load_shared_config
        cfg = load_shared_config()
        return {
            "current": "prepod",
            "thepod_url": cfg.get("thepod_url") or "",
            "apps": [
                {"key": "prepod",  "name": "prePod",  "icon": "🎙",
                 "url": cfg.get("prepod_url") or ""},
                {"key": "prodpod", "name": "prodPod", "icon": "🔴",
                 "url": cfg.get("prodpod_url") or ""},
                {"key": "postpod", "name": "postPod", "icon": "🎬",
                 "url": cfg.get("postpod_url") or ""},
                {"key": "amapod",  "name": "amaPod",  "icon": "❓",
                 "url": cfg.get("amapod_url") or ""},
            ],
        }

    # Media serving: browser uses cookie auth; postPod/prodPod (server-side)
    # use the X-PodPod-Secret header. Either works.
    def _media_auth_ok():
        if _sess.get("username"):
            return True
        from config import INTEGRATION_SECRET
        return _req.headers.get("X-PodPod-Secret") == INTEGRATION_SECRET

    def _serve_podcast_media(slug, subdir, filename):
        if not _media_auth_ok():
            abort(401)
        base = (PODCASTS_DIR / slug / subdir).resolve()
        target = (base / filename).resolve()
        if not str(target).startswith(str(base) + os.sep) and target != base:
            abort(403)
        from flask import request
        return _serve_with_range(target, request)

    @app.get("/media/podcasts/<slug>/branding/<path:filename>")
    def serve_branding(slug, filename):
        return _serve_podcast_media(slug, "branding", filename)

    @app.get("/media/podcasts/<slug>/sponsors/<path:filename>")
    def serve_sponsor_media(slug, filename):
        return _serve_podcast_media(slug, "sponsors", filename)

    @app.get("/media/podcasts/<slug>/guests/<path:filename>")
    def serve_guest_media(slug, filename):
        return _serve_podcast_media(slug, "guests", filename)

    import time as _time
    _boot_ts = str(int(_time.time()))

    from pod_lang import current_lang

    def _index():
        return render_template("index.html", cache_bust=_boot_ts, lang=current_lang(), cookie_domain=SESSION_COOKIE_DOMAIN or "")

    @app.get("/")
    def index():
        return _index()

    @app.get("/<path:path>")
    def spa(path):
        if path.startswith(("api/", "media/", "static/")):
            abort(404)
        return _index()

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5001, debug=True)
