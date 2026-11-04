"""Chat de un evento de amaPod: libre, moderado o sin chat.

Escriben el anfitrión (sesión), quien se anotó en la cola (`token` de participante) y el público que
solo mira (`chat_token`, que se pide con un nombre en POST /chat/join). En modo moderado lo del público
queda esperando hasta que el anfitrión lo aprueba; mientras tanto solo lo ven el anfitrión y quien lo
escribió. El anfitrión puede aprobar, quitar o no dejar escribir más a alguien.
"""

import secrets

from flask import Blueprint, jsonify, request, session

from auth import require_auth, current_user
from db import get_db
from pod_push import notify as push_notify

bp = Blueprint("chat_api", __name__)

MAX_LEN = 300          # caracteres por mensaje
MIN_GAP_S = 3          # segundos entre mensajes de la misma persona (el anfitrión no tiene límite)
MAX_NAME = 40


def _serialize_message(row, me=None):
    return {
        "id": row["id"],
        "event_id": row["event_id"],
        "sender_name": row["sender_name"],
        "is_host": row["is_host"],
        "message": row["message"],
        "is_approved": row["is_approved"],
        "pending": not row["is_approved"],
        "mine": bool(me and row["sender_key"] == me),
        "can_block": bool(row["sender_key"]) and not row["is_host"],
        "created_at": row["created_at"],
    }


def _arg(name):
    return request.args.get(name) or (request.get_json(silent=True) or {}).get(name)


def _sender(db, ev):
    """(nombre, es_anfitrión, llave) de quien pide, o (None, False, None)."""
    username = session.get("username")
    if username:
        return username, ev["host_username"] == username, f"host:{username}"
    token = _arg("token")
    if token:
        p = db.execute("SELECT id, display_name FROM participants WHERE event_id = ? AND access_token = ?",
                       (ev["id"], token)).fetchone()
        if p:
            return p["display_name"], False, f"p:{p['id']}"
    ct = _arg("chat_token")
    if ct:
        v = db.execute("SELECT id, name FROM chat_viewers WHERE event_id = ? AND token = ?",
                       (ev["id"], ct)).fetchone()
        if v:
            return v["name"], False, f"v:{v['id']}"
    return None, False, None


def _event(db, eid):
    return db.execute("SELECT * FROM events WHERE id = ?", (eid,)).fetchone()


@bp.post("/api/events/<int:eid>/chat/join")
def join_chat(eid):
    """El público que solo mira entra al chat con un nombre. Devuelve su llave para escribir."""
    db = get_db()
    try:
        ev = _event(db, eid)
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if ev["chat_mode"] == "off":
            return jsonify({"error": "el chat está desactivado"}), 403
        name = " ".join(((request.get_json(silent=True) or {}).get("name") or "").split())[:MAX_NAME]
        if not name:
            return jsonify({"error": "Escribe tu nombre"}), 400
        token = secrets.token_urlsafe(18)
        db.execute("INSERT INTO chat_viewers (event_id, token, name) VALUES (?, ?, ?)", (eid, token, name))
        db.commit()
        return jsonify({"chat_token": token, "name": name}), 201
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/chat")
def send_message(eid):
    db = get_db()
    try:
        ev = _event(db, eid)
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        if ev["chat_mode"] == "off":
            return jsonify({"error": "el chat está desactivado"}), 403

        sender_name, is_host, key = _sender(db, ev)
        if not sender_name:
            return jsonify({"error": "no autenticado"}), 401

        message = " ".join(((request.get_json(silent=True) or {}).get("message") or "").split())
        if not message:
            return jsonify({"error": "mensaje requerido"}), 400
        if len(message) > MAX_LEN:
            return jsonify({"error": f"Máximo {MAX_LEN} caracteres"}), 400

        if not is_host:
            if db.execute("SELECT 1 FROM chat_blocks WHERE event_id = ? AND sender_key = ?", (eid, key)).fetchone():
                return jsonify({"error": "El anfitrión no te deja escribir en este evento"}), 403
            last = db.execute(
                "SELECT (julianday('now') - julianday(created_at)) * 86400 AS ago FROM chat_messages "
                "WHERE event_id = ? AND sender_key = ? ORDER BY id DESC LIMIT 1", (eid, key)).fetchone()
            if last and last["ago"] is not None and last["ago"] < MIN_GAP_S:
                return jsonify({"error": "Espera un momento antes de escribir otra vez"}), 429

        # En modo moderado, lo que no escribe el anfitrión espera su aprobación
        is_approved = 0 if (ev["chat_mode"] == "moderated" and not is_host) else 1
        cur = db.execute(
            "INSERT INTO chat_messages (event_id, sender_name, is_host, message, is_approved, sender_key) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (eid, sender_name, 1 if is_host else 0, message, is_approved, key),
        )
        db.commit()
        row = db.execute("SELECT * FROM chat_messages WHERE id = ?", (cur.lastrowid,)).fetchone()
        if not is_approved:
            # Solo si el anfitrión tiene que decidir: un aviso por evento, se reemplaza con el último
            push_notify([ev["host_username"]], "amaPod · " + (ev["title"] or "evento"),
                        sender_name + " escribió en el chat y espera tu aprobación: «" + message[:80] + ("…" if len(message) > 80 else "") + "»",
                        "/ama/", tag="ama-chat-" + str(eid))
        return jsonify(_serialize_message(row, key)), 201
    finally:
        db.close()


@bp.get("/api/events/<int:eid>/chat")
def list_messages(eid):
    """Lo aprobado lo ve cualquiera que mira el evento. El anfitrión ve además lo que espera
    aprobación; cada persona ve también lo suyo que todavía espera."""
    db = get_db()
    try:
        ev = _event(db, eid)
        if not ev:
            return jsonify({"error": "evento no encontrado"}), 404
        _, is_host, key = _sender(db, ev)
        if is_host:
            rows = db.execute("SELECT * FROM chat_messages WHERE event_id = ? ORDER BY id ASC", (eid,)).fetchall()
        else:
            rows = db.execute(
                "SELECT * FROM chat_messages WHERE event_id = ? AND (is_approved = 1 OR sender_key = ?) "
                "ORDER BY id ASC", (eid, key or "")).fetchall()
        return jsonify([_serialize_message(r, key) for r in rows])
    finally:
        db.close()


def _host_message(db, eid, mid):
    """(evento, mensaje, error) comprobando que quien pide es el anfitrión."""
    ev = _event(db, eid)
    if not ev:
        return None, None, (jsonify({"error": "evento no encontrado"}), 404)
    if ev["host_username"] != current_user():
        return None, None, (jsonify({"error": "solo el anfitrión puede moderar el chat"}), 403)
    msg = db.execute("SELECT * FROM chat_messages WHERE id = ? AND event_id = ?", (mid, eid)).fetchone()
    if not msg:
        return None, None, (jsonify({"error": "mensaje no encontrado"}), 404)
    return ev, msg, None


@bp.post("/api/events/<int:eid>/chat/<int:mid>/approve")
@require_auth
def approve_message(eid, mid):
    db = get_db()
    try:
        _, msg, err = _host_message(db, eid, mid)
        if err:
            return err
        db.execute("UPDATE chat_messages SET is_approved = 1 WHERE id = ?", (mid,))
        db.commit()
        row = db.execute("SELECT * FROM chat_messages WHERE id = ?", (mid,)).fetchone()
        return jsonify(_serialize_message(row))
    finally:
        db.close()


@bp.delete("/api/events/<int:eid>/chat/<int:mid>")
@require_auth
def delete_message(eid, mid):
    db = get_db()
    try:
        _, msg, err = _host_message(db, eid, mid)
        if err:
            return err
        db.execute("DELETE FROM chat_messages WHERE id = ?", (mid,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.post("/api/events/<int:eid>/chat/<int:mid>/block")
@require_auth
def block_sender(eid, mid):
    """No deja escribir más a quien escribió este mensaje y quita todo lo suyo."""
    db = get_db()
    try:
        _, msg, err = _host_message(db, eid, mid)
        if err:
            return err
        key = msg["sender_key"]
        if not key or msg["is_host"]:
            return jsonify({"error": "a esa persona no se la puede bloquear"}), 400
        db.execute("INSERT OR IGNORE INTO chat_blocks (event_id, sender_key) VALUES (?, ?)", (eid, key))
        cur = db.execute("DELETE FROM chat_messages WHERE event_id = ? AND sender_key = ?", (eid, key))
        db.commit()
        return jsonify({"ok": True, "removed": cur.rowcount})
    finally:
        db.close()
