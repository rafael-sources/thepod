"""
Cobro de thePod con Lemon Squeezy: planes Web (9 USD/mes) y Mac (19 USD/mes).

Configuración en ~/.podpod/config.json (la crea el dueño de la cuenta de Lemon Squeezy):

    "lemonsqueezy": {
        "api_key": "…",              # Settings → API
        "store_id": "12345",
        "webhook_secret": "…",       # el «signing secret» del webhook
        "variants": {"web": "111", "mac": "222"},
        "test_mode": true            # mientras se prueba
    }

Flujo:
- POST /api/billing/checkout {plan}: crea un pago en Lemon Squeezy con el usuario adentro y
  devuelve la página de pago. Al pagar, Lemon Squeezy avisa al webhook.
- POST /api/billing/webhook: verifica la firma y, según el estado de la suscripción, deja la
  cuenta en el plan pagado o la devuelve a Gratis. Guarda el enlace al portal del cliente
  (cambiar de plan, tarjeta, facturas, cancelar).
- GET /api/billing/me: plan actual, renovación y enlace al portal.
"""

import hashlib
import hmac
import json
import sqlite3
import urllib.request
from pathlib import Path

from flask import Blueprint, jsonify, request, session

from plans import PLANS, limits_for, set_plan
from shared_config import load_shared_config

bp = Blueprint("billing", __name__)

DB = Path.home() / ".podpod" / "users.db"
API = "https://api.lemonsqueezy.com/v1"
PRICES = {"web": 9, "mac": 19}          # USD por mes (lo que se muestra; el cobro real lo define Lemon Squeezy)
ACTIVE = {"active", "on_trial", "past_due"}   # past_due: se le da tiempo a que pague antes de bajar el plan


def _cfg() -> dict:
    return load_shared_config().get("lemonsqueezy") or {}


def configured() -> bool:
    c = _cfg()
    return bool(c.get("api_key") and c.get("store_id") and (c.get("variants") or {}).get("web"))


def _db():
    c = sqlite3.connect(str(DB), timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("""CREATE TABLE IF NOT EXISTS subscriptions (
        username TEXT PRIMARY KEY, plan TEXT, status TEXT, ls_subscription_id TEXT, ls_customer_id TEXT,
        portal_url TEXT, renews_at TEXT, ends_at TEXT, updated_at TEXT NOT NULL DEFAULT (datetime('now')))""")
    return c


def _api(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Accept": "application/vnd.api+json",
                                          "Content-Type": "application/vnd.api+json",
                                          "Authorization": "Bearer " + _cfg()["api_key"]})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read() or b"{}")


@bp.get("/api/billing/me")
def billing_me():
    u = session.get("username")
    if not u:
        return jsonify({"error": "no autenticado"}), 401
    with _db() as c:
        row = c.execute("SELECT * FROM subscriptions WHERE username = ?", (u,)).fetchone()
    return jsonify({"plan": limits_for(u), "configured": configured(), "prices": PRICES,
                    "subscription": dict(row) if row else None})


@bp.post("/api/billing/checkout")
def billing_checkout():
    u = session.get("username")
    if not u:
        return jsonify({"error": "Entra con tu cuenta para elegir un plan."}), 401
    plan = ((request.get_json(silent=True) or {}).get("plan") or "").strip()
    if plan not in PRICES:
        return jsonify({"error": "plan inválido"}), 400
    if not configured():
        return jsonify({"error": "Los pagos todavía no están activos. Escríbenos a thepod@castmedia.space."}), 503
    from shared_users import get_user
    user = get_user(u) or {}
    cfg = _cfg()
    base = (load_shared_config().get("thepod_url") or request.host_url).rstrip("/")
    body = {"data": {
        "type": "checkouts",
        "attributes": {
            "checkout_data": {"email": user.get("email") or None, "name": user.get("display_name") or u,
                              "custom": {"username": u}},
            "product_options": {"redirect_url": base + "/planes?listo=1"},
            "test_mode": bool(cfg.get("test_mode")),
        },
        "relationships": {
            "store": {"data": {"type": "stores", "id": str(cfg["store_id"])}},
            "variant": {"data": {"type": "variants", "id": str(cfg["variants"][plan])}},
        },
    }}
    try:
        r = _api("POST", "/checkouts", body)
        return jsonify({"url": r["data"]["attributes"]["url"]})
    except Exception:
        return jsonify({"error": "No se pudo abrir el pago. Prueba de nuevo en un rato."}), 502


def _plan_for_variant(variant_id) -> str | None:
    for plan, vid in (_cfg().get("variants") or {}).items():
        if str(vid) == str(variant_id):
            return plan
    return None


@bp.post("/api/billing/webhook")
def billing_webhook():
    secret = (_cfg().get("webhook_secret") or "").encode()
    raw = request.get_data()
    sig = request.headers.get("X-Signature", "")
    if not secret or not hmac.compare_digest(hmac.new(secret, raw, hashlib.sha256).hexdigest(), sig):
        return jsonify({"error": "firma inválida"}), 401
    ev = json.loads(raw or b"{}")
    name = (ev.get("meta") or {}).get("event_name", "")
    if not name.startswith("subscription_"):
        return jsonify({"ok": True, "ignored": name})
    username = ((ev.get("meta") or {}).get("custom_data") or {}).get("username")
    data = ev.get("data") or {}
    a = data.get("attributes") or {}
    if not username:
        # Renovaciones y cambios: se busca por la suscripción guardada
        with _db() as c:
            row = c.execute("SELECT username FROM subscriptions WHERE ls_subscription_id = ?", (str(data.get("id")),)).fetchone()
        username = row["username"] if row else None
    if not username:
        return jsonify({"ok": True, "ignored": "sin usuario"})

    plan = _plan_for_variant(a.get("variant_id"))
    status = a.get("status") or ""
    with _db() as c:
        c.execute("""INSERT INTO subscriptions (username, plan, status, ls_subscription_id, ls_customer_id, portal_url,
                         renews_at, ends_at, updated_at) VALUES (?,?,?,?,?,?,?,?, datetime('now'))
                     ON CONFLICT(username) DO UPDATE SET plan=excluded.plan, status=excluded.status,
                         ls_subscription_id=excluded.ls_subscription_id, ls_customer_id=excluded.ls_customer_id,
                         portal_url=excluded.portal_url, renews_at=excluded.renews_at, ends_at=excluded.ends_at,
                         updated_at=datetime('now')""",
                  (username, plan, status, str(data.get("id")), str(a.get("customer_id") or ""),
                   ((a.get("urls") or {}).get("customer_portal") or ""), a.get("renews_at"), a.get("ends_at")))
    # Activa (o cancelada pero todavía dentro del mes pagado): plan pagado. Vencida o pausada: vuelve a Gratis.
    if plan in PLANS and (status in ACTIVE or (status == "cancelled" and a.get("ends_at"))):
        if status == "cancelled" and _past(a.get("ends_at")):
            set_plan(username, "gratis")
        else:
            set_plan(username, plan)
    elif status in {"expired", "unpaid", "paused"}:
        set_plan(username, "gratis")
    return jsonify({"ok": True})


def _past(iso: str | None) -> bool:
    if not iso:
        return True
    from datetime import datetime, timezone
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")) <= datetime.now(timezone.utc)
    except ValueError:
        return True
