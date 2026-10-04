"""
Stateless signed-cookie sessions. With a SECRET_KEY shared across the podpod
suite, logging into any app is automatically recognized by the other two on
the same host (or parent cookie domain).
"""

import uuid
from functools import wraps

from flask import Blueprint, jsonify, request, session
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

from config import USERS, SECRET_KEY, md5


bp = Blueprint("auth", __name__, url_prefix="/api/auth")

_token_serializer = URLSafeTimedSerializer(SECRET_KEY, salt="password-reset")
_RESET_MAX_AGE = 3600  # 1 hour


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
    if "@" in username:   # también se puede entrar con el correo
        from shared_users import list_user_rows
        username = next((r["username"] for r in list_user_rows()
                         if (r.get("email") or "").strip().lower() == username), username)
    expected = USERS.get(username)
    if not expected or md5(password) != expected:
        return jsonify({"error": "usuario o contraseña inválidos"}), 401

    session.clear()
    session["username"] = username
    session["sid"] = uuid.uuid4().hex
    session.permanent = True
    try:
        from shared_users import touch_last_login
        touch_last_login(username)
    except Exception:
        pass
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
    from shared_users import policy_for
    from plans import limits_for
    return jsonify({
        "username": username,
        "is_admin": bool(policy_for(username).get("see_all")),
        "plan": limits_for(username),
    })


# ---------------------------------------------------------------------------
# Password reset
# ---------------------------------------------------------------------------

def _find_user_by_identifier(identifier: str):
    """Find a user by username or email. Returns (username, user_dict) or None."""
    from shared_users import get_user, list_user_rows
    identifier = identifier.strip().lower()
    user = get_user(identifier)
    if user:
        return identifier, user
    for row in list_user_rows():
        if (row.get("email") or "").strip().lower() == identifier:
            return row["username"], row
    return None


@bp.post("/forgot-password")
def forgot_password():
    data = request.get_json(silent=True) or {}
    identifier = (data.get("identifier") or "").strip()
    if not identifier:
        return jsonify({"error": "ingresa tu usuario o email"}), 400

    result = _find_user_by_identifier(identifier)
    ok_msg = {"ok": True, "message": "Si el usuario existe y tiene email, recibirás un correo con instrucciones."}
    if not result:
        return jsonify(ok_msg)

    username, user = result
    email = (user.get("email") or "").strip()
    if not email:
        return jsonify(ok_msg)

    token = _token_serializer.dumps(username)

    from email_helper import _public_base_url, send_password_reset_email
    base = _public_base_url()
    reset_url = f"{base}/reset-password?token={token}" if base else f"/reset-password?token={token}"

    send_password_reset_email(
        to_email=email,
        display_name=user.get("display_name") or username,
        reset_url=reset_url,
    )

    return jsonify(ok_msg)


@bp.post("/reset-password")
def reset_password():
    data = request.get_json(silent=True) or {}
    token = (data.get("token") or "").strip()
    new_password = (data.get("password") or "").strip()

    if not token:
        return jsonify({"error": "token requerido"}), 400
    if not new_password or len(new_password) < 6:
        return jsonify({"error": "la contraseña debe tener al menos 6 caracteres"}), 400

    try:
        username = _token_serializer.loads(token, max_age=_RESET_MAX_AGE)
    except SignatureExpired:
        return jsonify({"error": "El enlace expiró. Solicita uno nuevo."}), 400
    except BadSignature:
        return jsonify({"error": "Enlace inválido."}), 400

    from shared_users import get_user, update_user_fields
    user = get_user(username)
    if not user:
        return jsonify({"error": "usuario no encontrado"}), 404

    update_user_fields(username, {"password_md5": md5(new_password)})
    return jsonify({"ok": True, "message": "Contraseña actualizada. Ya puedes iniciar sesión."})
