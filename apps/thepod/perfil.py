"""
Mi perfil: nombre, correo, contraseña y foto de cada usuario.

La foto se guarda en ~/.podpod/avatars/<usuario>.jpg (fuera del repo) y la
ven todas las apps de la suite en /avatar/<usuario>.jpg. El navegador la
recorta y achica a 256x256 antes de subirla, así el servidor no necesita
librerías de imágenes: solo valida que sea un JPEG razonable.

Cambiar el correo o la contraseña pide la contraseña actual.
"""

import os
import re
from pathlib import Path

from flask import Blueprint, abort, jsonify, render_template, request, send_file, session

from shared_users import get_user, list_user_rows, md5, update_user_fields

bp = Blueprint("perfil", __name__)

AVATAR_DIR = Path.home() / ".podpod" / "avatars"
MAX_AVATAR_BYTES = 600 * 1024
_USER_RE = re.compile(r"^[a-z0-9._-]{1,64}$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _avatar_path(username: str) -> Path | None:
    if not username or not _USER_RE.match(username):
        return None
    return AVATAR_DIR / f"{username}.jpg"


def avatar_url(username: str) -> str | None:
    """URL relativa de la foto (con versión para que el navegador no use una vieja)."""
    p = _avatar_path(username)
    if not p or not p.exists():
        return None
    return f"/avatar/{username}.jpg?v={int(p.stat().st_mtime)}"


def _me():
    u = session.get("username")
    if not u:
        return None, (jsonify({"error": "Inicia sesión para ver tu perfil."}), 401)
    user = get_user(u)
    if not user:
        return None, (jsonify({"error": "Tu usuario ya no existe."}), 404)
    return user, None


def _public(user: dict) -> dict:
    from plans import limits_for
    return {
        "username": user["username"],
        "display_name": user["display_name"],
        "email": user["email"],
        "avatar_color": user["avatar_color"],
        "avatar_url": avatar_url(user["username"]),
        "plan": limits_for(user["username"]),
    }


@bp.get("/perfil")
def perfil_page():
    return render_template("perfil.html", username=session.get("username"),
                           app_key=None, app_cfg=None, section=None, section_labels=None,
                           prev_section=None, next_section=None, app_urls={})


@bp.get("/api/perfil")
def perfil_get():
    user, err = _me()
    if err:
        return err
    return jsonify(_public(user))


@bp.post("/api/perfil")
def perfil_update():
    """Cambia el nombre (libre) y/o el correo (pide la contraseña actual)."""
    user, err = _me()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    fields = {}

    if "display_name" in data:
        name = (data.get("display_name") or "").strip()
        if not name:
            return jsonify({"error": "Escribe tu nombre."}), 400
        if len(name) > 60:
            return jsonify({"error": "El nombre es muy largo (máximo 60 letras)."}), 400
        fields["display_name"] = name

    if "email" in data:
        email = (data.get("email") or "").strip().lower()
        if email != (user["email"] or "").strip().lower():
            if md5(data.get("password") or "") != user["password_md5"]:
                return jsonify({"error": "Para cambiar el correo escribe tu contraseña actual."}), 403
            if email and not _EMAIL_RE.match(email):
                return jsonify({"error": "Ese correo no parece válido."}), 400
            if email and any((r.get("email") or "").strip().lower() == email
                             and r["username"] != user["username"] for r in list_user_rows()):
                return jsonify({"error": "Ese correo ya lo usa otra cuenta."}), 409
            if not email:
                return jsonify({"error": "Necesitas un correo para recuperar tu contraseña."}), 400
            fields["email"] = email

    if fields:
        user = update_user_fields(user["username"], fields)
    return jsonify({"ok": True, **_public(user)})


@bp.post("/api/perfil/clave")
def perfil_password():
    user, err = _me()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    current = data.get("current") or ""
    new = data.get("new") or ""
    if md5(current) != user["password_md5"]:
        return jsonify({"error": "La contraseña actual no es correcta."}), 403
    if len(new) < 8:
        return jsonify({"error": "La nueva contraseña necesita al menos 8 caracteres."}), 400
    if new == current:
        return jsonify({"error": "La nueva contraseña es igual a la actual."}), 400
    update_user_fields(user["username"], {"password_md5": md5(new)})
    return jsonify({"ok": True})


@bp.post("/api/perfil/avatar")
def perfil_avatar_upload():
    user, err = _me()
    if err:
        return err
    f = request.files.get("foto")
    raw = f.read(MAX_AVATAR_BYTES + 1) if f else request.get_data(cache=False)[:MAX_AVATAR_BYTES + 1]
    if not raw:
        return jsonify({"error": "No llegó ninguna foto."}), 400
    if len(raw) > MAX_AVATAR_BYTES:
        return jsonify({"error": "La foto es muy pesada."}), 413
    if not (raw[:3] == b"\xff\xd8\xff" and raw[-2:] == b"\xff\xd9"):
        return jsonify({"error": "La foto debe ser una imagen JPG."}), 400
    p = _avatar_path(user["username"])
    if not p:
        return jsonify({"error": "Usuario inválido."}), 400
    AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_bytes(raw)
    os.replace(tmp, p)
    return jsonify({"ok": True, "avatar_url": avatar_url(user["username"])})


@bp.delete("/api/perfil/avatar")
def perfil_avatar_delete():
    user, err = _me()
    if err:
        return err
    p = _avatar_path(user["username"])
    if p and p.exists():
        p.unlink()
    return jsonify({"ok": True, "avatar_url": None})


@bp.get("/avatar/<username>.jpg")
def avatar_file(username):
    p = _avatar_path(username.lower())
    if not p or not p.exists():
        abort(404)
    resp = send_file(str(p), mimetype="image/jpeg", conditional=True, max_age=86400)
    resp.headers["Access-Control-Allow-Origin"] = "*"
    return resp
