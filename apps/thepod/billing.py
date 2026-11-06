"""
thePod billing with Lemon Squeezy: Web (9 USD/month) and Mac (19 USD/month) plans.

Configuration in ~/.podpod/config.json (created by the Lemon Squeezy account owner):

    "lemonsqueezy": {
        "api_key": "…",              # Settings → API
        "store_id": "12345",
        "webhook_secret": "…",       # the webhook "signing secret"
        "test_mode": true            # while testing; false = real charges
    }
    Each plan's variants are looked up automatically in the store and stored separately per mode
    ("variants_test" / "variants_live"), because test and live products have different numbers.
    }

Flow:
- POST /api/billing/checkout {plan}: creates a Lemon Squeezy checkout with the user embedded and
  returns the payment page. On payment, Lemon Squeezy notifies the webhook.
- POST /api/billing/webhook: verifies the signature and, depending on the subscription status, puts the
  account on the paid plan or returns it to Gratis. Stores the customer portal link
  (change plan, card, invoices, cancel).
- GET /api/billing/me: current plan, renewal and portal link. If the subscription has already expired and
  the Lemon Squeezy notification never arrived, it downgrades here.
- Anyone who had the Completo plan (older accounts) and pays goes back to Completo on cancel, not to Gratis.
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
PRICES = {"web": 9, "mac": 19}          # USD per month (what is displayed; the actual charge is defined by Lemon Squeezy)
ACTIVE = {"active", "on_trial", "past_due"}   # past_due: give them time to pay before downgrading the plan


def _cfg() -> dict:
    return load_shared_config().get("lemonsqueezy") or {}


def configured() -> bool:
    c = _cfg()
    return bool(c.get("api_key") and c.get("store_id") and _variants().get("web") and _variants().get("mac"))


def _mode() -> str:
    return "test" if _cfg().get("test_mode") else "live"


def _variants() -> dict:
    """Each plan's variants in the current mode. If not stored, they are looked up once in the store: the
    9 USD monthly subscription is Web and the 19 USD one is Mac (or products named "Web" / "Mac")."""
    c = _cfg()
    key = "variants_" + _mode()
    v = c.get(key) or (c.get("variants") if _mode() == "test" else None) or {}   # "variants" = the older test ones
    if v.get("web") and v.get("mac") or not c.get("api_key"):
        return v
    try:
        data = _api("GET", f"/variants?page[size]=50").get("data") or []
        prods = {p["id"]: (p["attributes"].get("name") or "").lower()
                 for p in (_api("GET", f"/products?filter[store_id]={c.get('store_id')}").get("data") or [])}
        found = {}
        for item in data:
            a = item["attributes"]
            if not a.get("is_subscription"):
                continue
            pname = prods.get(str(a.get("product_id")), "")
            if pname not in [n for n in prods.values()]:
                continue
            if a.get("price") == PRICES["web"] * 100 or "web" in pname:
                found.setdefault("web", item["id"])
            if a.get("price") == PRICES["mac"] * 100 or "mac" in pname:
                found.setdefault("mac", item["id"])
        if found.get("web") and found.get("mac"):
            from shared_config import update_shared_config
            c[key] = found
            update_shared_config({"lemonsqueezy": c})
            return found
    except Exception:
        pass
    return v


def _db():
    c = sqlite3.connect(str(DB), timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("""CREATE TABLE IF NOT EXISTS subscriptions (
        username TEXT PRIMARY KEY, plan TEXT, status TEXT, ls_subscription_id TEXT, ls_customer_id TEXT,
        portal_url TEXT, renews_at TEXT, ends_at TEXT, updated_at TEXT NOT NULL DEFAULT (datetime('now')))""")
    cols = {r["name"] for r in c.execute("PRAGMA table_info(subscriptions)")}
    if "prev_plan" not in cols:      # the plan they had before paying, to restore it on cancel
        try:
            c.execute("ALTER TABLE subscriptions ADD COLUMN prev_plan TEXT")
        except sqlite3.OperationalError:
            pass
    return c


def _plan_after_paid(username: str) -> str:
    """Which plan they return to when they stop paying: Completo if they had it before paying; otherwise Gratis."""
    with _db() as c:
        row = c.execute("SELECT prev_plan FROM subscriptions WHERE username = ?", (username,)).fetchone()
    return "completo" if row and row["prev_plan"] == "completo" else "gratis"


def _reconcile(username: str) -> None:
    """In case the Lemon Squeezy notification was lost: a cancelled subscription whose paid month has passed is downgraded."""
    with _db() as c:
        row = c.execute("SELECT * FROM subscriptions WHERE username = ?", (username,)).fetchone()
    if not row or row["status"] != "cancelled" or not _past(row["ends_at"]):
        return
    set_plan(username, _plan_after_paid(username))
    with _db() as c:
        c.execute("UPDATE subscriptions SET status = 'expired', updated_at = datetime('now') WHERE username = ?",
                  (username,))


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
    _reconcile(u)
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
            "checkout_data": {k: v for k, v in {"email": user.get("email"), "name": user.get("display_name") or u,
                                                "custom": {"username": u}}.items() if v},
            "product_options": {"redirect_url": base + "/planes?listo=1"},
            "test_mode": bool(cfg.get("test_mode")),
        },
        "relationships": {
            "store": {"data": {"type": "stores", "id": str(cfg["store_id"])}},
            "variant": {"data": {"type": "variants", "id": str(_variants()[plan])}},
        },
    }}
    try:
        r = _api("POST", "/checkouts", body)
        return jsonify({"url": r["data"]["attributes"]["url"]})
    except Exception as e:
        detail = e.read()[:300] if hasattr(e, "read") else str(e)
        print("billing checkout error:", detail, flush=True)
        return jsonify({"error": "No se pudo abrir el pago. Prueba de nuevo en un rato."}), 502


def _plan_for_variant(variant_id) -> str | None:
    for plan, vid in _variants().items():
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
    meta = ev.get("meta") or {}
    name = meta.get("event_name", "")
    if not name.startswith("subscription_"):
        return jsonify({"ok": True, "ignored": name})
    if "test_mode" in meta and bool(meta["test_mode"]) != bool(_cfg().get("test_mode")):
        # A test payment does not change plans when charging for real (nor vice versa)
        return jsonify({"ok": True, "ignored": "otro modo"})
    username = (meta.get("custom_data") or {}).get("username")
    data = ev.get("data") or {}
    a = data.get("attributes") or {}
    payment = name.startswith("subscription_payment_")
    sub_id = a.get("subscription_id") if payment else data.get("id")
    if not sub_id:
        return jsonify({"ok": True, "ignored": "sin suscripción"})
    # Notifications may arrive out of order: what counts is the subscription state NOW, not what the notification says.
    try:
        data = _api("GET", f"/subscriptions/{sub_id}").get("data") or data
        a = data.get("attributes") or a
    except Exception:
        if payment:      # the invoice alone does not tell the status
            return jsonify({"ok": True, "ignored": "no se pudo leer la suscripción"})
    if not username:
        # Renewals and changes: look up by the stored subscription
        with _db() as c:
            row = c.execute("SELECT username FROM subscriptions WHERE ls_subscription_id = ?", (str(data.get("id")),)).fetchone()
        username = row["username"] if row else None
    if not username:
        return jsonify({"ok": True, "ignored": "sin usuario"})

    plan = _plan_for_variant(a.get("variant_id"))
    status = a.get("status") or ""
    from plans import plan_of
    before = plan_of(username)
    with _db() as c:
        c.execute("""INSERT INTO subscriptions (username, plan, status, ls_subscription_id, ls_customer_id, portal_url,
                         renews_at, ends_at, prev_plan, updated_at) VALUES (?,?,?,?,?,?,?,?,?, datetime('now'))
                     ON CONFLICT(username) DO UPDATE SET plan=excluded.plan, status=excluded.status,
                         ls_subscription_id=excluded.ls_subscription_id, ls_customer_id=excluded.ls_customer_id,
                         portal_url=excluded.portal_url, renews_at=excluded.renews_at, ends_at=excluded.ends_at,
                         updated_at=datetime('now')""",
                  (username, plan, status, str(data.get("id")), str(a.get("customer_id") or ""),
                   ((a.get("urls") or {}).get("customer_portal") or ""), a.get("renews_at"), a.get("ends_at"),
                   before if before not in PRICES else None))
    # Active (or cancelled but still within the paid month): paid plan. Expired or paused: back to Gratis.
    if plan in PLANS and (status in ACTIVE or (status == "cancelled" and a.get("ends_at"))):
        if status == "cancelled" and _past(a.get("ends_at")):
            set_plan(username, _plan_after_paid(username))
        else:
            set_plan(username, plan)
    elif status in {"expired", "unpaid", "paused"}:
        set_plan(username, _plan_after_paid(username))
    return jsonify({"ok": True})


def _past(iso: str | None) -> bool:
    if not iso:
        return True
    from datetime import datetime, timezone
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")) <= datetime.now(timezone.utc)
    except ValueError:
        return True
