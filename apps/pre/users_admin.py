"""
Admin-only user management. Reads/writes the shared SQLite users DB at
`~/.podpod/users.db` so changes propagate to prodPod and postPod.
"""

import re
from shared_users import hash_password

from flask import Blueprint, jsonify, request

from auth import current_user, require_auth
from shared_users import (
    list_user_rows, get_user, create_user, update_user_fields,
    delete_user_by_name, admins_count_excluding,
    md5, random_password, policy_for,
)
from plans import PLANS, limits_for, set_plan


bp = Blueprint("users_admin", __name__, url_prefix="/api/users")

_USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{2,31}$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _check_email(email):
    """None if valid (or empty); otherwise, the error message."""
    email = (email or "").strip()
    if email and not _EMAIL_RE.match(email):
        return "el correo no parece válido"
    return None


def _is_admin() -> bool:
    return policy_for(current_user()).get("see_all") is True


def _serialize(row: dict) -> dict:
    """Public view — never include password hashes."""
    lim = limits_for(row["username"])
    return {
        "username":      row["username"],
        "display_name":  row["display_name"],
        "email":         row.get("email") or "",
        "avatar_color":  row["avatar_color"],
        "is_admin":      row["is_admin"],
        "max_podcasts":  row["max_podcasts"],
        "created_at":    row.get("created_at"),
        "last_login_at": row.get("last_login_at"),
        "plan":          lim["plan"],
        "episodes_used": lim["episodes_used"],
        "max_episodes":  lim["max_episodes"],
    }


@bp.get("")
@require_auth
def list_users():
    if not _is_admin():
        return jsonify({"error": "solo admins"}), 403
    return jsonify([_serialize(r) for r in list_user_rows()])


@bp.post("")
@require_auth
def create_user_endpoint():
    if not _is_admin():
        return jsonify({"error": "solo admins"}), 403
    body = request.get_json(silent=True) or {}
    username = (body.get("username") or "").strip().lower()
    if not _USERNAME_RE.match(username):
        return jsonify({"error": "el usuario debe tener de 3 a 32 caracteres: letras, números, _ o -, sin espacios"}), 400
    if get_user(username):
        return jsonify({"error": f"el usuario «{username}» ya existe"}), 400
    bad = _check_email(body.get("email"))
    if bad:
        return jsonify({"error": bad}), 400

    password = (body.get("password") or "").strip()
    auto_password = None
    if not password:
        password = random_password()
        auto_password = password

    is_admin = bool(body.get("is_admin"))
    max_podcasts = body.get("max_podcasts")
    if max_podcasts is not None:
        try: max_podcasts = max(0, int(max_podcasts))
        except (TypeError, ValueError): max_podcasts = None

    try:
        row = create_user(
            username, password,
            display_name=body.get("display_name"),
            email=body.get("email"),
            avatar_color=body.get("avatar_color"),
            is_admin=is_admin,
            max_podcasts=max_podcasts,
        )
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    plan = body.get("plan") or "completo"
    if plan in PLANS and not is_admin:
        set_plan(username, plan)
        row = get_user(username)

    out = _serialize(row)
    if auto_password:
        out["generated_password"] = auto_password
    return jsonify(out), 201


@bp.put("/<username>")
@require_auth
def update_user_endpoint(username):
    if not _is_admin():
        return jsonify({"error": "solo admins"}), 403
    username = (username or "").strip().lower()
    existing = get_user(username)
    if not existing:
        return jsonify({"error": "usuario no encontrado"}), 404

    body = request.get_json(silent=True) or {}
    fields = {}
    out_extra = {}

    if "password" in body:
        new_pw = (body.get("password") or "").strip()
        if not new_pw:
            new_pw = random_password()
            out_extra["generated_password"] = new_pw
        if len(new_pw) < 6:
            return jsonify({"error": "la contraseña debe tener al menos 6 caracteres"}), 400
        fields["password_md5"] = hash_password(new_pw)

    if "display_name" in body:
        fields["display_name"] = (body["display_name"] or username).strip().title()
    if "avatar_color" in body:
        fields["avatar_color"] = (body["avatar_color"] or "").strip() or None
    if "email" in body:
        bad = _check_email(body.get("email"))
        if bad:
            return jsonify({"error": bad}), 400
        fields["email"] = (body["email"] or "").strip() or None

    if "is_admin" in body:
        wanted = bool(body["is_admin"])
        if not wanted and existing["is_admin"]:
            if admins_count_excluding(username) == 0:
                return jsonify({"error": "no puedes dejar al sistema sin admins"}), 400
            if username == current_user():
                return jsonify({"error": "no puedes quitarte tu propio rol de admin"}), 400
        fields["is_admin"] = 1 if wanted else 0
        if wanted:
            fields["max_podcasts"] = None

    will_be_admin = bool(fields["is_admin"]) if "is_admin" in fields else bool(existing["is_admin"])
    if "max_podcasts" in body:
        if will_be_admin:
            pass  # admins ignore the limit
        else:
            v = body["max_podcasts"]
            if v in (None, ""):
                fields["max_podcasts"] = None
            else:
                try: v = max(0, int(v))
                except (TypeError, ValueError):
                    return jsonify({"error": "max_podcasts debe ser entero o null"}), 400
                fields["max_podcasts"] = v

    if "plan" in body:
        if body["plan"] not in PLANS:
            return jsonify({"error": "plan inválido"}), 400
        set_plan(username, body["plan"])

    try:
        row = update_user_fields(username, fields) if fields else get_user(username)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    out = _serialize(row)
    out.update(out_extra)
    return jsonify(out)


@bp.delete("/<username>")
@require_auth
def delete_user_endpoint(username):
    if not _is_admin():
        return jsonify({"error": "solo admins"}), 403
    username = (username or "").strip().lower()
    if username == current_user():
        return jsonify({"error": "no puedes borrar tu propio usuario"}), 400
    existing = get_user(username)
    if not existing:
        return jsonify({"error": "usuario no encontrado"}), 404
    if existing["is_admin"] and admins_count_excluding(username) == 0:
        return jsonify({"error": "no puedes borrar al último admin"}), 400
    try:
        delete_user_by_name(username)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    return jsonify({"ok": True})
