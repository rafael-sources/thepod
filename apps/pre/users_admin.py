"""
Admin-only user management. Reads/writes the shared SQLite users DB at
`~/.podpod/users.db` so changes propagate to prodPod and postPod.
"""

from flask import Blueprint, jsonify, request

from auth import current_user, require_auth
from shared_users import (
    list_user_rows, get_user, create_user, update_user_fields,
    delete_user_by_name, admins_count_excluding,
    md5, random_password, policy_for,
)


bp = Blueprint("users_admin", __name__, url_prefix="/api/users")


def _is_admin() -> bool:
    return policy_for(current_user()).get("see_all") is True


def _serialize(row: dict) -> dict:
    """Public view — never include password hashes."""
    return {
        "username":      row["username"],
        "display_name":  row["display_name"],
        "email":         row.get("email") or "",
        "avatar_color":  row["avatar_color"],
        "is_admin":      row["is_admin"],
        "max_podcasts":  row["max_podcasts"],
        "created_at":    row.get("created_at"),
        "last_login_at": row.get("last_login_at"),
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
    if not username or not username.replace("_", "").replace("-", "").isalnum():
        return jsonify({"error": "username inválido (solo letras, números, _ -)"}), 400

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
        fields["password_md5"] = md5(new_pw)

    if "display_name" in body:
        fields["display_name"] = (body["display_name"] or username).strip().title()
    if "avatar_color" in body:
        fields["avatar_color"] = (body["avatar_color"] or "").strip() or None
    if "email" in body:
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

    if "max_podcasts" in body and "is_admin" not in fields:
        if existing["is_admin"]:
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

    try:
        row = update_user_fields(username, fields)
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
