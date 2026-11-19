import mimetypes
import os
import re
import time
from datetime import timedelta
from pathlib import Path

from flask import Flask, Response, abort, render_template, send_from_directory

import auth
import captions
import export_api
import files as files_bp
import integrations
import projects
import review
import startup
import timeline_api
import transcript_api
from auth import require_auth
from config import GLOBAL_DIR, MEDIA_TYPES, PROJECTS_DIR, SECRET_KEY


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
    # Trust one Apache/nginx hop in front for X-Forwarded-{Proto,Host,For}.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    app.config["SECRET_KEY"] = SECRET_KEY
    # 12 GB: a ~50 min 1080p recording weighs ~2.7 GB and the previous cap
    # of 2 GB made prodPod get a 413 when sending tracks to postPod.
    app.config["MAX_CONTENT_LENGTH"] = 12 * 1024 * 1024 * 1024
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_NAME"] = "podpod_session"
    if SESSION_COOKIE_DOMAIN:
        app.config["SESSION_COOKIE_DOMAIN"] = SESSION_COOKIE_DOMAIN
    app.permanent_session_lifetime = timedelta(days=7)

    app.register_blueprint(auth.bp)
    app.register_blueprint(projects.bp)
    app.register_blueprint(files_bp.bp)
    app.register_blueprint(timeline_api.bp)
    app.register_blueprint(export_api.bp)
    app.register_blueprint(integrations.bp)
    app.register_blueprint(captions.bp)
    app.register_blueprint(transcript_api.bp)
    import export_review
    app.register_blueprint(export_review.bp)
    app.register_blueprint(review.bp)

    # Per-project access guard for restricted users.
    import re as _re
    from flask import request as _req, session as _sess, jsonify as _json
    _SLUG_RE = _re.compile(r"^/api/projects/([A-Za-z0-9_-]+)(?:/|$)")

    @app.before_request
    def _enforce_project_access():
        path = _req.path or ""
        if path in ("/api/projects", "/api/projects/"):
            return None
        m = _SLUG_RE.match(path)
        if not m:
            return None
        username = _sess.get("username")
        if not username:
            return None
        from config import policy_for as _pol
        if _pol(username).get("see_all"):
            return None
        slug = m.group(1)
        from projects import _read_meta as _rm
        from shared_users import default_owner as _default_owner
        meta = _rm(slug)
        if not meta:
            return None
        owner = meta.get("owner_username") or _default_owner()
        extras = meta.get("extra_hosts") or []
        if username != owner and username not in extras:
            return _json({"error": "no autorizado para este proyecto"}), 403
        return None

    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    GLOBAL_DIR.mkdir(parents=True, exist_ok=True)

    # One-shot background maintenance (missing thumbnails, etc).
    startup.run_background_maintenance_once()

    @app.get("/media/projects/<slug>/<file_type>/<path:filename>")
    @require_auth
    def serve_project_media(slug, file_type, filename):
        if file_type not in MEDIA_TYPES:
            abort(404)
        base = (PROJECTS_DIR / slug / "media" / file_type).resolve()
        target = (base / filename).resolve()
        if not str(target).startswith(str(base) + os.sep) and target != base:
            abort(403)
        from flask import request
        return _serve_with_range(target, request)

    @app.get("/media/global/<file_type>/<path:filename>")
    @require_auth
    def serve_global_media(file_type, filename):
        if file_type not in MEDIA_TYPES:
            abort(404)
        base = (GLOBAL_DIR / file_type).resolve()
        target = (base / filename).resolve()
        if not str(target).startswith(str(base) + os.sep) and target != base:
            abort(403)
        from flask import request
        return _serve_with_range(target, request)

    @app.get("/api/config/apps")
    def list_apps():
        from shared_config import load_shared_config
        cfg = load_shared_config()
        return {
            "current": "postpod",
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

    def _lang():
        """Interface language: pod_lang cookie (set by the switch, shared across the domain) or the browser."""
        from flask import request as _r
        c = _r.cookies.get("pod_lang")
        if c in ("es", "en"):
            return c
        return "en" if (_r.accept_languages.best_match(["es", "en"]) == "en") else "es"

    def _index():
        return render_template("index.html", cache_bust=int(time.time()), lang=_lang(), cookie_domain=SESSION_COOKIE_DOMAIN or "")

    @app.get("/")
    def index():
        return _index()

    # SPA catch-all for any client-side route that isn't an API or media URL
    @app.get("/<path:path>")
    def spa(path):
        if path.startswith(("api/", "media/", "static/")):
            abort(404)
        return _index()

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5000, debug=True)
