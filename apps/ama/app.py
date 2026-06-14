from datetime import timedelta
import time as _time
from flask import Flask, abort, render_template
import auth
from config import SECRET_KEY, EVENTS_DIR

def create_app():
    from config import SESSION_COOKIE_DOMAIN
    from werkzeug.middleware.proxy_fix import ProxyFix

    app = Flask(__name__, static_folder="static", template_folder="templates")
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    app.config["SECRET_KEY"] = SECRET_KEY
    app.config["MAX_CONTENT_LENGTH"] = 500 * 1024 * 1024
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_NAME"] = "podpod_session"
    if SESSION_COOKIE_DOMAIN:
        app.config["SESSION_COOKIE_DOMAIN"] = SESSION_COOKIE_DOMAIN
    app.permanent_session_lifetime = timedelta(days=7)

    app.register_blueprint(auth.bp)

    import events_api
    app.register_blueprint(events_api.bp)

    import queue_api
    app.register_blueprint(queue_api.bp)

    import recording_api
    app.register_blueprint(recording_api.bp)

    import chat_api
    app.register_blueprint(chat_api.bp)

    import integrations
    app.register_blueprint(integrations.bp)

    EVENTS_DIR.mkdir(parents=True, exist_ok=True)

    _boot_ts = str(int(_time.time()))

    @app.get("/api/config/apps")
    def list_apps():
        from shared_config import load_shared_config
        cfg = load_shared_config()
        return {
            "current": "amapod",
            "thepod_url": cfg.get("thepod_url") or "",
            "apps": [
                {"key": "prepod",  "name": "prePod",  "icon": "\U0001f399", "url": cfg.get("prepod_url") or ""},
                {"key": "prodpod", "name": "prodPod", "icon": "\U0001f534", "url": cfg.get("prodpod_url") or ""},
                {"key": "postpod", "name": "postPod", "icon": "\U0001f3ac", "url": cfg.get("postpod_url") or ""},
                {"key": "amapod",  "name": "amaPod",  "icon": "❓",    "url": cfg.get("amapod_url") or ""},
            ],
        }

    @app.get("/api/config/livekit")
    def livekit_config():
        from config import LIVEKIT_WS_URL
        return {"ws_url": LIVEKIT_WS_URL}

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
    app.run(host="0.0.0.0", port=5003, debug=True)
