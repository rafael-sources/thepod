"""
Stateless signed-cookie sessions. With a SECRET_KEY shared across the podpod
suite (prePod / postPod / prodPod), logging into any app is automatically
recognized by the other two on the same host (or parent cookie domain).
"""

import uuid
from functools import wraps
from shared_users import verify_password, hash_password

from flask import Blueprint, jsonify, request, session

from config import USERS, md5


bp = Blueprint("auth", __name__, url_prefix="/api/auth")


def require_auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("username"):
            return jsonify({"error": "no autenticado"}), 401
        return f(*args, **kwargs)
    return wrapper


def current_user():
    return session.get("username")


@bp.post("/login")
def login():
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip().lower()
    password = data.get("password") or ""
    if "@" in username:   # logging in with the email also works
        from shared_users import list_user_rows
        username = next((r["username"] for r in list_user_rows()
                         if (r.get("email") or "").strip().lower() == username), username)
    if not verify_password(username, password):
        return jsonify({"error": "usuario o contraseña inválidos"}), 401

    session.clear()
    session["username"] = username
    session["sid"] = uuid.uuid4().hex
    session.permanent = True
    return jsonify({"username": username})


@bp.post("/logout")
def logout():
    session.clear()
    return jsonify({"ok": True})


@bp.get("/me")
def me():
    username = session.get("username")
    if not username:
        return jsonify({"error": "no autenticado"}), 401
    return jsonify({"username": username})
