import mimetypes
import os
import re
from datetime import timedelta
from pathlib import Path

from flask import Flask, Response, abort, render_template

import auth
import branding as branding_bp
import episodes as episodes_bp
import integrations as integrations_bp
import landing as landing_bp
import podcasts
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

    PODCASTS_DIR.mkdir(parents=True, exist_ok=True)

    @app.get("/api/config/fonts")
    @require_auth
    def list_fonts():
        return {"fonts": AVAILABLE_FONTS}

    @app.get("/media/podcasts/<slug>/branding/<path:filename>")
    @require_auth
    def serve_branding(slug, filename):
        base = (PODCASTS_DIR / slug / "branding").resolve()
        target = (base / filename).resolve()
        if not str(target).startswith(str(base) + os.sep) and target != base:
            abort(403)
        from flask import request
        return _serve_with_range(target, request)

    import time as _time
    _boot_ts = str(int(_time.time()))

    @app.get("/")
    def index():
        return render_template("index.html", cache_bust=_boot_ts)

    @app.get("/<path:path>")
    def spa(path):
        if path.startswith(("api/", "media/", "static/")):
            abort(404)
        return render_template("index.html", cache_bust=_boot_ts)

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5001, debug=True)
