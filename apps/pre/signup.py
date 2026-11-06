"""
Self-service signup with confirmed email — HIDDEN until launch.

Only works with the `signup_key` from ~/.podpod/config.json (shared as a
link: /registro?clave=…). Without that key in the config, signup is closed to everyone.

Flow:
1. POST /api/auth/signup  {clave, display_name, email, password}
   → stores a pending request (does not create the user) and sends an email with a link.
2. POST /api/auth/signup/confirm {token}
   → creates the user (non-admin, 1 podcast) and starts the session.

Pending requests live in ~/.podpod/signups.db (the password is already hashed;
it never travels in the link). The link expires after 24 h.
"""

import hmac
import re
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from shared_users import hash_password

from flask import Blueprint, jsonify, request, session
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from config import SECRET_KEY, md5
from shared_config import load_shared_config


bp = Blueprint("signup", __name__, url_prefix="/api/auth/signup")

_serializer = URLSafeTimedSerializer(SECRET_KEY, salt="signup-confirm")
_MAX_AGE = 24 * 3600
_DB = Path.home() / ".podpod" / "signups.db"
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_lock = threading.Lock()
_hits: dict[str, list[float]] = {}          # ip → timestamps (simple anti-abuse rate limit)
FREE_MAX_PODCASTS = 1


def _key_ok(clave: str) -> bool:
    key = (load_shared_config().get("signup_key") or "").strip()
    return bool(key) and hmac.compare_digest(key, (clave or "").strip())


def _conn():
    _DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(_DB)
    c.row_factory = sqlite3.Row
    c.execute("""CREATE TABLE IF NOT EXISTS pending (
        id TEXT PRIMARY KEY, email TEXT NOT NULL, display_name TEXT NOT NULL,
        password_md5 TEXT NOT NULL, created_at REAL NOT NULL, used INTEGER NOT NULL DEFAULT 0)""")
    return c


def _rate_limited(ip: str, limit: int = 5, window: float = 3600) -> bool:
    now = time.time()
    with _lock:
        recent = [t for t in _hits.get(ip, []) if now - t < window]
        recent.append(now)
        _hits[ip] = recent
        return len(recent) > limit


def _email_taken(email: str) -> bool:
    from shared_users import list_user_rows
    return any((r.get("email") or "").strip().lower() == email for r in list_user_rows())


def _free_username(email: str) -> str:
    """Username from the email: «maria.garcia@x.com» → «mariagarcia» (or «mariagarcia2»…)."""
    from shared_users import get_user
    base = re.sub(r"[^a-z0-9_-]", "", email.split("@")[0].lower())[:28] or "usuario"
    if len(base) < 3:
        base = (base + "pod")[:3]
    name, n = base, 2
    while get_user(name):
        name = f"{base}{n}"
        n += 1
    return name


@bp.get("/open")
def is_open():
    """Does this key open signup? (the signup screen only appears if so)."""
    return jsonify({"open": _key_ok(request.args.get("clave", ""))})


@bp.post("")
def signup():
    data = request.get_json(silent=True) or {}
    if not _key_ok(data.get("clave", "")):
        return jsonify({"error": "El registro todavía no está abierto."}), 403
    if _rate_limited(request.headers.get("X-Forwarded-For", request.remote_addr or "?").split(",")[0].strip()):
        return jsonify({"error": "Demasiados intentos. Prueba de nuevo en una hora."}), 429

    name = " ".join((data.get("display_name") or "").split())[:60]
    email = (data.get("email") or "").strip().lower()
    password = data.get("password") or ""
    if len(name) < 2:
        return jsonify({"error": "Escribe tu nombre."}), 400
    if not _EMAIL_RE.match(email):
        return jsonify({"error": "El correo no parece válido."}), 400
    if len(password) < 8:
        return jsonify({"error": "La contraseña debe tener al menos 8 caracteres."}), 400

    ok = {"ok": True, "message": f"Te mandamos un correo a {email}. Abre el enlace para activar tu cuenta (vence en 24 horas)."}
    if _email_taken(email):
        # Same message as if it were new: does not reveal which emails have an account.
        return jsonify(ok)

    sid = uuid.uuid4().hex
    with _conn() as c:
        c.execute("DELETE FROM pending WHERE created_at < ?", (time.time() - 2 * _MAX_AGE,))
        c.execute("INSERT INTO pending (id, email, display_name, password_md5, created_at) VALUES (?,?,?,?,?)",
                  (sid, email, name, hash_password(password), time.time()))
    token = _serializer.dumps(sid)

    from email_helper import _public_base_url, send_signup_confirm_email, is_configured
    if not is_configured():
        return jsonify({"error": "No se pudo mandar el correo de confirmación. Escríbenos para activarte."}), 503
    base = _public_base_url()
    url = f"{base}/registro/confirmar?token={token}" if base else f"/registro/confirmar?token={token}"
    r = send_signup_confirm_email(to_email=email, display_name=name, confirm_url=url)
    if isinstance(r, dict) and r.get("ok") is False:
        return jsonify({"error": "No se pudo mandar el correo de confirmación. Prueba de nuevo en un rato."}), 502
    return jsonify(ok)


@bp.post("/confirm")
def confirm():
    token = ((request.get_json(silent=True) or {}).get("token") or "").strip()
    try:
        sid = _serializer.loads(token, max_age=_MAX_AGE)
    except SignatureExpired:
        return jsonify({"error": "El enlace venció. Regístrate de nuevo."}), 400
    except BadSignature:
        return jsonify({"error": "El enlace no es válido."}), 400

    with _conn() as c:
        row = c.execute("SELECT * FROM pending WHERE id = ?", (sid,)).fetchone()
        if not row:
            return jsonify({"error": "El enlace no es válido."}), 400
        if row["used"]:
            return jsonify({"error": "Esta cuenta ya está activada. Entra con tu correo y tu contraseña."}), 400
        if _email_taken(row["email"]):
            c.execute("UPDATE pending SET used = 1 WHERE id = ?", (sid,))
            return jsonify({"error": "Ya hay una cuenta con ese correo. Entra con tu contraseña o recupérala."}), 400

        from shared_users import create_user, update_user_fields
        username = _free_username(row["email"])
        # create_user takes the plaintext password; create with a random one and set the stored hash.
        create_user(username, secrets.token_urlsafe(12), display_name=row["display_name"], email=row["email"],
                    is_admin=False, max_podcasts=FREE_MAX_PODCASTS)
        update_user_fields(username, {"password_md5": row["password_md5"]})
        from plans import set_plan
        set_plan(username, "gratis")        # self-signups always start on Gratis
        c.execute("UPDATE pending SET used = 1 WHERE id = ?", (sid,))

    session.clear()
    session["username"] = username
    session["sid"] = uuid.uuid4().hex
    session.permanent = True
    return jsonify({"ok": True, "username": username})
