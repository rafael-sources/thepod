# Billing scenarios with a fake Lemon Squeezy (temporary HOME). Run: python3 tests/billing_escenarios.py
import hashlib, hmac, json, os, sqlite3, sys, tempfile
from datetime import datetime, timedelta, timezone
home = tempfile.mkdtemp(); os.environ["HOME"] = home
os.makedirs(home + "/.podpod")
json.dump({"secret_key": "a", "integration_secret": "b", "lemonsqueezy": {"api_key": "k", "store_id": "1", "webhook_secret": "s", "test_mode": False,
                            "variants": {"web": "T1", "mac": "T2"}, "variants_live": {"web": "L1", "mac": "L2"}}},
          open(home + "/.podpod/config.json", "w"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
c = sqlite3.connect(home + "/.podpod/users.db")
c.execute("CREATE TABLE users (username TEXT PRIMARY KEY, is_admin INT DEFAULT 0, plan TEXT)")
c.executemany("INSERT INTO users (username, plan) VALUES (?,?)", [("ana", "gratis"), ("viejo", None)])
c.commit()
import billing, plans
from flask import Flask
app = Flask(__name__); app.secret_key = "x"; app.register_blueprint(billing.bp)
cl = app.test_client()
STATE = {}
def fake_api(method, path, body=None):
    sid = path.rsplit("/", 1)[-1]; return {"data": STATE[sid]}
billing._api = fake_api
def hook(name, sub, username=None, test=False, payment=False):
    data = {"id": "inv9", "attributes": {"subscription_id": sub}} if payment else {"id": sub, "attributes": {"status": "whatever"}}
    ev = {"meta": {"event_name": name, "test_mode": test, **({"custom_data": {"username": username}} if username else {})}, "data": data}
    raw = json.dumps(ev).encode()
    return cl.post("/api/billing/webhook", data=raw, headers={"X-Signature": hmac.new(b"s", raw, hashlib.sha256).hexdigest()}).get_json()
iso = lambda d: (datetime.now(timezone.utc) + timedelta(days=d)).isoformat()
def sub(sid, variant, status, ends=None):
    STATE[sid] = {"id": sid, "attributes": {"variant_id": variant, "status": status, "ends_at": ends, "customer_id": 5, "urls": {}}}
ok = lambda cond, msg: print(("OK  " if cond else "FAIL ") + msg)

ok(billing._variants() == {"web": "L1", "mac": "L2"}, "live mode uses the live variants, not the test ones")
sub("10", "L2", "active"); hook("subscription_created", "10", "ana")
ok(plans.plan_of("ana") == "mac", "Gratis pays Mac -> Mac")
r = hook("subscription_created", "10", "ana", test=True)
ok(r.get("ignored") == "otro modo", "test-mode notification is ignored in live mode")
# an old 'updated' notification arrives but the subscription is already expired: the current state wins
sub("10", "L2", "expired"); hook("subscription_updated", "10")
ok(plans.plan_of("ana") == "gratis", "expired -> Gratis (even if the notification has no user)")
# older Completo account pays and cancels
sub("20", "L1", "active"); hook("subscription_created", "20", "viejo")
ok(plans.plan_of("viejo") == "web", "Completo pays Web -> Web")
sub("20", "L1", "cancelled", iso(10)); hook("subscription_cancelled", "20")
ok(plans.plan_of("viejo") == "web", "cancelled with a paid month ahead -> stays Web")
# the expiry notification is lost: the month has passed
with billing._db() as d: d.execute("UPDATE subscriptions SET ends_at=? WHERE username='viejo'", (iso(-1),))
with app.test_request_context(): pass
with cl.session_transaction() as s: s["username"] = "viejo"
me = cl.get("/api/billing/me").get_json()
ok(plans.plan_of("viejo") == "completo" and me["plan"]["plan"] == "completo", "month expired without notification -> back to Completo on query")
sub("10", "L2", "active"); hook("subscription_payment_success", "10", payment=True)
ok(plans.plan_of("ana") == "mac", "invoice paid (renewal) -> back to Mac")
for i in range(5): plans.claim_episode("ana", f"mac:ep{i}")
sub("10", "L2", "expired"); hook("subscription_expired", "10")
ok(plans.plan_of("ana") == "gratis", "stops paying -> Gratis")
ok(plans.claim_episode("ana", "mac:ep3")[0], "on Gratis can still open an episode made while paying")
ok(not plans.claim_episode("ana", "mac:nuevo")[0], "on Gratis cannot create a new one (already used more than 2)")
