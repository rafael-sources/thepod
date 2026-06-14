from datetime import timedelta
import time as _time

from flask import Flask, abort, render_template

import auth
import director_api
import integrations as integrations_bp
import recordings_api
import sessions_api
import streams_api
from config import SECRET_KEY, SESSIONS_DIR


def create_app():
    from config import SESSION_COOKIE_DOMAIN
    from werkzeug.middleware.proxy_fix import ProxyFix

    app = Flask(__name__, static_folder="static", template_folder="templates")
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    app.config["SECRET_KEY"] = SECRET_KEY
    app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 * 1024 * 1024  # 2 GB (future recording uploads)
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_NAME"] = "podpod_session"
    if SESSION_COOKIE_DOMAIN:
        app.config["SESSION_COOKIE_DOMAIN"] = SESSION_COOKIE_DOMAIN
    app.permanent_session_lifetime = timedelta(days=7)

    app.register_blueprint(auth.bp)
    app.register_blueprint(sessions_api.bp)
    app.register_blueprint(integrations_bp.bp)
    app.register_blueprint(recordings_api.bp)
    app.register_blueprint(streams_api.bp)
    app.register_blueprint(director_api.bp)

    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    # Per-session access guard for restricted users.
    import re as _re
    from flask import request as _req, session as _sess, jsonify as _json
    _SID_RE = _re.compile(r"^/api/sessions/(\d+)(?:/|$)")

    @app.before_request
    def _enforce_session_access():
        path = _req.path or ""
        m = _SID_RE.match(path)
        if not m:
            return None
        username = _sess.get("username")
        if not username:
            return None
        from config import policy_for
        if policy_for(username).get("see_all"):
            return None
        try:
            sid = int(m.group(1))
        except ValueError:
            return None
        from db import get_db as _gdb
        try:
            _db = _gdb()
            row = _db.execute("SELECT created_by FROM sessions WHERE id=?", (sid,)).fetchone()
            if not row:
                _db.close()
                return None
            if row["created_by"] == username:
                _db.close()
                return None
            p = _db.execute(
                "SELECT 1 FROM participants WHERE session_id=? AND username=?",
                (sid, username),
            ).fetchone()
            _db.close()
            if not p:
                return _json({"error": "no autorizado para esta sesión"}), 403
        except Exception:
            return None
        return None

    # One-shot migrations on startup (idempotent)
    import logging
    _log = logging.getLogger(__name__)
    try:
        from migrations.update_recordings_schema import run as _upd_rec
        _upd_rec()
    except Exception as _e:
        _log.warning("recordings schema migration skipped: %s", _e)
    try:
        from migrations.sync_default_sounds import run as _sync_defaults
        _sync_defaults()
    except Exception as _e:
        _log.warning("default sounds sync skipped: %s", _e)
    try:
        from migrations.cleanup_auto_added_cohosts import run as _cleanup_cohosts
        _log.info("cleanup_auto_added_cohosts: %s", _cleanup_cohosts())
    except Exception as _e:
        _log.warning("cohost cleanup skipped: %s", _e)

    _boot_ts = str(int(_time.time()))

    @app.get("/api/config/apps")
    def list_apps():
        from shared_config import load_shared_config
        cfg = load_shared_config()
        return {
            "current": "prodpod",
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

    @app.get("/")
    def index():
        return render_template("index.html", cache_bust=_boot_ts)

    @app.get("/<path:path>")
    def spa(path):
        if path.startswith(("api/", "static/", "media/")):
            abort(404)
        return render_template("index.html", cache_bust=_boot_ts)

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5002, debug=True)
