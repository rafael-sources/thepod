"""
Planes de thePod — el mismo archivo en prePod, prodPod, postPod y thePod.

- Completo: sin límites (todas las cuentas que ya existían y las que un admin marque así).
- Web (de pago): sin límites en la web; en la app de Mac, lo del plan Gratis.
- Mac (de pago): sin límites en la web y en la app.
- Gratis: 2 episodios en total (una vez hechos, no se pueden hacer más), grabaciones de hasta
  15 minutos y video hasta 720p.

Se guarda en la base compartida de usuarios (~/.podpod/users.db):
- users.plan: NULL o "completo" = Completo · "gratis" = Gratis.
- plan_usage: qué episodios ya contaron (uno por grabación de prodPod, proyecto subido a postPod
  o proyecto nuevo en la app de Mac). Un episodio que ya contó se puede seguir usando siempre.
"""

import sqlite3
from pathlib import Path

USERS_DB = Path.home() / ".podpod" / "users.db"

PLANS = {
    "gratis":   {"name": "Gratis",   "max_episodes": 2,    "max_record_seconds": 15 * 60, "max_height": 720,  "mac": False},
    # De pago (Lemon Squeezy): Web = todo en el navegador; Mac = web + la app de Mac
    "web":      {"name": "Web",      "max_episodes": None, "max_record_seconds": None,    "max_height": None, "mac": False},
    "mac":      {"name": "Mac",      "max_episodes": None, "max_record_seconds": None,    "max_height": None, "mac": True},
    # Cuentas de antes y las que marca un admin: todo, sin cobro
    "completo": {"name": "Completo", "max_episodes": None, "max_record_seconds": None,    "max_height": None, "mac": True},
}
# Sin la app incluida (Gratis y Web), en la Mac rige lo del plan Gratis
MAC_FREE = {"max_episodes": 2, "max_height": 720}


def _connect():
    USERS_DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(str(USERS_DB), timeout=10)
    c.row_factory = sqlite3.Row
    cols = {r["name"] for r in c.execute("PRAGMA table_info(users)")}
    if cols and "plan" not in cols:
        try:
            c.execute("ALTER TABLE users ADD COLUMN plan TEXT")
        except sqlite3.OperationalError:
            pass        # otra app la agregó al mismo tiempo
    c.execute("""CREATE TABLE IF NOT EXISTS plan_usage (
        username TEXT NOT NULL, ref TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')),
        PRIMARY KEY (username, ref))""")
    c.commit()
    return c


def plan_of(username: str) -> str:
    if not username:
        return "completo"
    try:
        with _connect() as c:
            row = c.execute("SELECT plan, is_admin FROM users WHERE username = ?", (username,)).fetchone()
    except sqlite3.Error:
        return "completo"
    if not row or row["is_admin"]:
        return "completo"
    return row["plan"] if row["plan"] in PLANS else "completo"


def set_plan(username: str, plan: str) -> None:
    if plan not in PLANS:
        raise ValueError("plan inválido")
    with _connect() as c:
        c.execute("UPDATE users SET plan = ? WHERE username = ?", (plan, username))


def episodes_used(username: str) -> int:
    with _connect() as c:
        return c.execute("SELECT COUNT(*) FROM plan_usage WHERE username = ?", (username,)).fetchone()[0]


def limits_for(username: str) -> dict:
    """Lo que puede hacer esta cuenta, para mostrar y para que las apps lo apliquen."""
    plan = plan_of(username)
    out = {"plan": plan, **PLANS[plan]}
    out["episodes_used"] = episodes_used(username) if username else 0
    out["episodes_left"] = None if out["max_episodes"] is None else max(0, out["max_episodes"] - out["episodes_used"])
    return out


def claim_episode(username: str, ref: str):
    """Cuenta un episodio nuevo. Devuelve (True, None) si se puede, o (False, mensaje) si se acabó el plan.
    Si `ref` ya contó antes (la misma grabación, el mismo proyecto), siempre se puede."""
    lim = limits_for(username)
    with _connect() as c:
        if c.execute("SELECT 1 FROM plan_usage WHERE username = ? AND ref = ?", (username, ref)).fetchone():
            return True, None
        if ref.startswith("mac:") and not lim["mac"] and lim["plan"] != "gratis":
            # Plan Web: la app de Mac funciona como Gratis (cuentan solo los episodios hechos en la Mac)
            used_mac = c.execute("SELECT COUNT(*) FROM plan_usage WHERE username = ? AND ref LIKE 'mac:%'",
                                 (username,)).fetchone()[0]
            if used_mac >= MAC_FREE["max_episodes"]:
                return False, (f"El plan {lim['name']} no incluye la app de Mac: ahí se pueden hacer "
                               f"{MAC_FREE['max_episodes']} episodios de prueba y ya los usaste. Pásate al plan Mac para seguir.")
            c.execute("INSERT OR IGNORE INTO plan_usage (username, ref) VALUES (?, ?)", (username, ref))
            return True, None
        if lim["max_episodes"] is not None and lim["episodes_used"] >= lim["max_episodes"]:
            return False, (f"El plan {lim['name']} incluye {lim['max_episodes']} episodios y ya los usaste. "
                           "Mejora tu plan para seguir.")
        c.execute("INSERT OR IGNORE INTO plan_usage (username, ref) VALUES (?, ?)", (username, ref))
    return True, None
