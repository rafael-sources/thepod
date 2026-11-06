"""
thePod · notifications (web push) for the PWA.

A single origin (thepod.castmedia.space) stores one subscription per phone and per user.
The other apps do not talk to the browser: they ask thePod to notify, with the shared
secret:

    POST /api/push/send   X-PodPod-Secret: …
    {"usernames": ["admin"], "title": "amaPod", "body": "Ana pide la palabra", "url": "/ama/"}

What the user sees:
    GET  /api/push/key          → the public key (VAPID) to subscribe
    POST /api/push/subscribe    → stores the browser subscription (session)
    POST /api/push/unsubscribe  → deletes it
    POST /api/push/test         → sends a notification to yourself, to check

VAPID keys are created only once and live in ~/.podpod/vapid.json. Subscriptions
in ~/.podpod/push.db. If pywebpush is not installed, everything answers "not available" without breaking.
"""
from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

from flask import Flask, jsonify, request, session

SHARED_DIR = Path.home() / ".podpod"
VAPID_FILE = SHARED_DIR / "vapid.json"
DB_FILE = SHARED_DIR / "push.db"

try:
    from pywebpush import webpush, WebPushException
    from py_vapid import Vapid
    from py_vapid.utils import b64urlencode
    HAVE_PUSH = True
except Exception:  # pragma: no cover
    HAVE_PUSH = False


def _vapid() -> dict:
    """{'private_pem': str, 'public_key': str (base64url, raw 65 bytes)}"""
    if VAPID_FILE.exists():
        try:
            d = json.loads(VAPID_FILE.read_text())
            if d.get("private_pem") and d.get("public_key"):
                return d
        except (OSError, ValueError):
            pass
    if not HAVE_PUSH:
        return {}
    v = Vapid()
    v.generate_keys()
    from cryptography.hazmat.primitives import serialization
    pem = v.private_key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    raw = v.public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    d = {"private_pem": pem, "public_key": b64urlencode(raw)}
    SHARED_DIR.mkdir(parents=True, exist_ok=True)
    VAPID_FILE.write_text(json.dumps(d))
    try:
        VAPID_FILE.chmod(0o600)
    except OSError:
        pass
    return d


def _db() -> sqlite3.Connection:
    SHARED_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_FILE), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS subscriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        endpoint TEXT NOT NULL UNIQUE,
        p256dh TEXT NOT NULL,
        auth TEXT NOT NULL,
        ua TEXT,
        created_at INTEGER NOT NULL,
        last_ok INTEGER
    )""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sub_user ON subscriptions(username)")
    return conn


def send_to(usernames: list[str], title: str, body: str = "", url: str = "/", tag: str | None = None,
            icon: str = "/static/pwa/icon-192.png") -> dict:
    """Sends the notification to all those users' phones. Returns how many went out and how many were unsubscribed."""
    if not HAVE_PUSH:
        return {"sent": 0, "dropped": 0, "error": "pywebpush no instalado"}
    keys = _vapid()
    payload = json.dumps({"title": title, "body": body, "url": url, "tag": tag or url, "icon": icon})
    sent = dropped = 0
    with _db() as conn:
        rows = conn.execute(
            f"SELECT * FROM subscriptions WHERE username IN ({','.join('?' * len(usernames))})", list(usernames)
        ).fetchall() if usernames else []
        for r in rows:
            sub = {"endpoint": r["endpoint"], "keys": {"p256dh": r["p256dh"], "auth": r["auth"]}}
            try:
                webpush(sub, payload, vapid_private_key=keys["private_pem"],
                        vapid_claims={"sub": "mailto:hola@castmedia.space"}, ttl=600, timeout=8)
                sent += 1
                conn.execute("UPDATE subscriptions SET last_ok=? WHERE id=?", (int(time.time()), r["id"]))
            except WebPushException as e:
                code = getattr(getattr(e, "response", None), "status_code", None)
                if code in (404, 410):   # the phone unsubscribed
                    conn.execute("DELETE FROM subscriptions WHERE id=?", (r["id"],))
                    dropped += 1
            except Exception:
                pass
    return {"sent": sent, "dropped": dropped}


def install(app: Flask, cfg: dict) -> None:
    @app.get("/api/push/key")
    def push_key():
        k = _vapid()
        if not k:
            return jsonify({"ok": False, "msg": "Los avisos no están disponibles en este servidor."}), 503
        return jsonify({"ok": True, "public_key": k["public_key"]})

    @app.post("/api/push/subscribe")
    def push_subscribe():
        u = session.get("username")
        if not u:
            return jsonify({"ok": False, "msg": "no autenticado"}), 401
        d = request.get_json(silent=True) or {}
        sub = d.get("subscription") or d
        ep = sub.get("endpoint")
        keys = sub.get("keys") or {}
        if not ep or not keys.get("p256dh") or not keys.get("auth"):
            return jsonify({"ok": False, "msg": "suscripción incompleta"}), 400
        with _db() as conn:
            conn.execute("""INSERT INTO subscriptions (username, endpoint, p256dh, auth, ua, created_at)
                            VALUES (?,?,?,?,?,?)
                            ON CONFLICT(endpoint) DO UPDATE SET username=excluded.username,
                                p256dh=excluded.p256dh, auth=excluded.auth, ua=excluded.ua""",
                         (u, ep, keys["p256dh"], keys["auth"], (request.user_agent.string or "")[:200], int(time.time())))
        return jsonify({"ok": True})

    @app.post("/api/push/unsubscribe")
    def push_unsubscribe():
        u = session.get("username")
        if not u:
            return jsonify({"ok": False, "msg": "no autenticado"}), 401
        d = request.get_json(silent=True) or {}
        ep = d.get("endpoint")
        with _db() as conn:
            if ep:
                conn.execute("DELETE FROM subscriptions WHERE endpoint=? AND username=?", (ep, u))
            else:
                conn.execute("DELETE FROM subscriptions WHERE username=?", (u,))
        return jsonify({"ok": True})

    @app.post("/api/push/test")
    def push_test():
        u = session.get("username")
        if not u:
            return jsonify({"ok": False, "msg": "no autenticado"}), 401
        r = send_to([u], "thePod", "Los avisos funcionan en este teléfono.", "/pre/", tag="test")
        return jsonify({"ok": True, **r})

    @app.post("/api/push/send")
    def push_send():
        secret = cfg.get("integration_secret") or ""
        if not secret or request.headers.get("X-PodPod-Secret", "") != secret:
            return jsonify({"ok": False, "msg": "no autorizado"}), 403
        d = request.get_json(silent=True) or {}
        users = [str(x) for x in (d.get("usernames") or []) if x]
        if not users or not d.get("title"):
            return jsonify({"ok": False, "msg": "faltan usernames o title"}), 400
        r = send_to(users, str(d["title"])[:80], str(d.get("body") or "")[:200], str(d.get("url") or "/"), d.get("tag"))
        return jsonify({"ok": True, **r})
