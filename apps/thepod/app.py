"""
ThePod — central landing/hub for the podpod suite.

Single-purpose tiny Flask app. Lets you log in once with the shared SSO
session, then shows 3 cards (prePod, prodPod, postPod) with one-click
"Entrar" buttons.

No business logic of its own — auth/users live in shared_users.
"""

import json
from datetime import timedelta
from pathlib import Path

from flask import Flask, abort, jsonify, redirect, render_template, request, send_file, session
from werkzeug.middleware.proxy_fix import ProxyFix

from shared_config import load_shared_config
from shared_users import md5, policy_for, touch_last_login, users_passwords


def create_app():
    app = Flask(__name__, static_folder="static", template_folder="templates")
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    cfg = load_shared_config()
    app.config["SECRET_KEY"] = cfg["secret_key"]
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_NAME"] = "podpod_session"
    if cfg.get("cookie_domain"):
        app.config["SESSION_COOKIE_DOMAIN"] = cfg["cookie_domain"]
    app.permanent_session_lifetime = timedelta(days=7)

    @app.get("/")
    def index():
        return render_template("landing.html",
                               username=session.get("username"),
                               is_admin=bool(policy_for(session.get("username")).get("see_all")))

    @app.post("/api/login")
    def login():
        data = request.get_json(silent=True) or {}
        username = (data.get("username") or "").strip().lower()
        password = data.get("password") or ""
        passwords = users_passwords()
        expected = passwords.get(username)
        if not expected or md5(password) != expected:
            return jsonify({"error": "usuario o contraseña inválidos"}), 401
        session.clear()
        session["username"] = username
        import uuid as _u
        session["sid"] = _u.uuid4().hex
        session.permanent = True
        try:
            touch_last_login(username)
        except Exception:
            pass
        return jsonify({"username": username})

    @app.post("/api/logout")
    def logout():
        session.clear()
        return jsonify({"ok": True})

    @app.get("/api/me")
    def me():
        u = session.get("username")
        if not u:
            return jsonify({"error": "no autenticado"}), 401
        return jsonify({
            "username": u,
            "is_admin": bool(policy_for(u).get("see_all")),
        })

    # ----- Documentation routes -----
    # The docs live inside thePod (no separate site) so the SSO cookie keeps
    # working and links between apps stay on a single domain. Each app has
    # its own theme + section ordering; the same base template renders all.

    DOCS_APPS = {
        "prepod":  {"name": "prePod",  "icon": "🎙",
                    "tag": "Pre-producción",
                    "sections": ["overview", "quickstart", "conceptos",
                                 "funcionalidades", "atajos", "integraciones", "faq"]},
        "prodpod": {"name": "prodPod", "icon": "🔴",
                    "tag": "Estudio en vivo",
                    "sections": ["overview", "quickstart", "conceptos",
                                 "funcionalidades", "atajos", "integraciones", "faq"]},
        "postpod": {"name": "postPod", "icon": "🎬",
                    "tag": "Edición y publicación",
                    "sections": ["overview", "quickstart", "conceptos",
                                 "funcionalidades", "atajos", "integraciones", "faq"]},
        "postpodapp": {"name": "thePod para Mac", "icon": "💻",
                    "tag": "App para Mac",
                    "sections": ["overview", "quickstart", "conceptos",
                                 "funcionalidades", "integraciones", "faq"]},
        "amapod":  {"name": "amaPod",  "icon": "❓",
                    "tag": "Q&A en vivo",
                    "sections": ["overview", "quickstart", "conceptos",
                                 "funcionalidades", "integraciones", "faq"]},
    }

    SECTION_LABELS = {
        "overview":         "Vista general",
        "quickstart":       "Quickstart",
        "conceptos":        "Conceptos",
        "funcionalidades":  "Funcionalidades",
        "atajos":           "Atajos",
        "integraciones":    "Integraciones",
        "faq":              "FAQ",
    }

    def _app_urls():
        cfg2 = load_shared_config()
        return {
            "prepod":  cfg2.get("prepod_url")  or "",
            "prodpod": cfg2.get("prodpod_url") or "",
            "postpod": cfg2.get("postpod_url") or "",
            "postpodapp": "",
            "amapod":  cfg2.get("amapod_url")  or "",
        }

    @app.get("/docs")
    @app.get("/docs/")
    def docs_index():
        return render_template("docs/index.html",
                               apps=DOCS_APPS,
                               app_urls=_app_urls(),
                               username=session.get("username"))

    @app.get("/docs/<app_key>")
    @app.get("/docs/<app_key>/")
    def docs_app_root(app_key):
        if app_key not in DOCS_APPS:
            return ("doc no encontrada", 404)
        return docs_section(app_key, "overview")

    @app.get("/docs/<app_key>/<section>")
    def docs_section(app_key, section):
        if app_key not in DOCS_APPS:
            return ("doc no encontrada", 404)
        cfg = DOCS_APPS[app_key]
        if section not in cfg["sections"]:
            return ("sección no encontrada", 404)
        # Resolve prev / next within this app's section list for the footer
        order = cfg["sections"]
        idx = order.index(section)
        prev_section = order[idx - 1] if idx > 0 else None
        next_section = order[idx + 1] if idx + 1 < len(order) else None
        return render_template(
            f"docs/{app_key}/{section}.html",
            app_key=app_key,
            app_cfg=cfg,
            apps=DOCS_APPS,
            section=section,
            section_labels=SECTION_LABELS,
            prev_section=prev_section,
            next_section=next_section,
            app_urls=_app_urls(),
            username=session.get("username"),
        )

    # ----- Descargas (solo con sesión) -----
    # El .dmg y su ficha viven fuera del repo: ~/.podpod/downloads/thePod.dmg y thePod.json
    # (o "downloads_dir" en ~/.podpod/config.json). scripts/publish-thepod-mac.sh los deja ahí.

    def _downloads_dir() -> Path:
        cfg2 = load_shared_config()
        return Path(cfg2.get("downloads_dir") or (Path.home() / ".podpod" / "downloads"))

    def _mac_info():
        d = _downloads_dir()
        dmg, meta = d / "thePod.dmg", d / "thePod.json"
        if not dmg.is_file():
            return None
        info = {}
        try:
            info = json.loads(meta.read_text())
        except (OSError, ValueError):
            pass
        info.setdefault("size", dmg.stat().st_size)
        return info

    @app.get("/descargas")
    def descargas():
        return render_template("descargas.html",
                               username=session.get("username"),
                               mac_app=_mac_info())

    @app.get("/api/descargas/postpod-mac")
    def descargas_mac_info():
        if not session.get("username"):
            return jsonify({"error": "no autenticado"}), 401
        info = _mac_info()
        if not info:
            return jsonify({"error": "todavía no hay una versión publicada"}), 404
        return jsonify(info)

    @app.get("/descargas/postpod-mac")
    def descargas_postpod_mac_old():
        return redirect("/descargas/thepod-mac")

    @app.get("/descargas/thepod-mac")
    def descargas_mac():
        if not session.get("username"):
            return redirect("/descargas")
        info = _mac_info()
        if not info:
            abort(404)
        version = info.get("version") or "mac"
        return send_file(str(_downloads_dir() / "thePod.dmg"), as_attachment=True,
                         download_name=f"thePod-{version}.dmg",
                         mimetype="application/x-apple-diskimage", conditional=True, max_age=0)

    @app.get("/api/apps")
    def apps_list():
        cfg2 = load_shared_config()
        return jsonify([
            {"key": "prepod",  "name": "prePod",  "icon": "🎙",
             "tag":  "Pre-producción",
             "desc": "Planeas el episodio: identidad del podcast, episodios, "
                     "guion, rundown, invitados y calendario.",
             "url":  cfg2.get("prepod_url") or ""},
            {"key": "prodpod", "name": "prodPod", "icon": "🔴",
             "tag":  "Estudio en vivo",
             "desc": "Grabas con tus invitados por WebRTC: video + audio multipista, "
                     "soundboard, chat, RTMP a YouTube/Twitch.",
             "url":  cfg2.get("prodpod_url") or ""},
            {"key": "postpod", "name": "postPod", "icon": "🎬",
             "tag":  "Edición y publicación",
             "desc": "Editas no-destructivo: cortes, zoom, momentos, subtítulos "
                     "(Whisper), formato vertical TikTok, exportas listo para subir.",
             "url":  cfg2.get("postpod_url") or ""},
            {"key": "amapod",  "name": "amaPod",  "icon": "❓",
             "tag":  "Q&A en vivo",
             "desc": "Abre una sesión de preguntas con tu audiencia: cola dinámica, "
                     "video en vivo, chat, y grabación automática.",
             "url":  cfg2.get("amapod_url") or ""},
        ])

    return app


if __name__ == "__main__":
    create_app().run(host="0.0.0.0", port=5003, debug=True)
