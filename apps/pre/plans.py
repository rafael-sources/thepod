"""
thePod plans — the same file in prePod, prodPod, postPod and thePod.

- Completo: no limits (all pre-existing accounts and those an admin marks as such).
- Web (paid): no limits on the web; in the Mac app, the Gratis plan limits.
- Mac (paid): no limits on the web or in the app.
- Gratis: 2 episodes in total (once made, no more can be made), recordings up to
  15 minutes and video up to 720p.

Stored in the shared users database (~/.podpod/users.db):
- users.plan: NULL or "completo" = Completo · "gratis" = Gratis.
- plan_usage: which episodes have already counted (one per prodPod recording, project uploaded to postPod
  or new project in the Mac app). An episode that already counted can always keep being used.
"""

import sqlite3
from pathlib import Path

USERS_DB = Path.home() / ".podpod" / "users.db"

PLANS = {
    "gratis":   {"name": "Gratis",   "max_episodes": 2,    "max_record_seconds": 15 * 60, "max_height": 720,  "mac": False},
    # Paid (Lemon Squeezy): Web = everything in the browser; Mac = web + the Mac app
    "web":      {"name": "Web",      "max_episodes": None, "max_record_seconds": None,    "max_height": None, "mac": False},
    "mac":      {"name": "Mac",      "max_episodes": None, "max_record_seconds": None,    "max_height": None, "mac": True},
    # Older accounts and those an admin marks: everything, free of charge
    "completo": {"name": "Completo", "max_episodes": None, "max_record_seconds": None,    "max_height": None, "mac": True},
}
# Without the app included (Gratis and Web), the Gratis plan limits apply on the Mac
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
            pass        # another app added it at the same time
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
    """What this account can do, for display and for the apps to enforce."""
    plan = plan_of(username)
    out = {"plan": plan, **PLANS[plan]}
    out["episodes_used"] = episodes_used(username) if username else 0
    out["episodes_left"] = None if out["max_episodes"] is None else max(0, out["max_episodes"] - out["episodes_used"])
    return out


def claim_episode(username: str, ref: str):
    """Counts a new episode. Returns (True, None) if allowed, or (False, message) if the plan is used up.
    If `ref` already counted before (same recording, same project), it is always allowed."""
    lim = limits_for(username)
    with _connect() as c:
        if c.execute("SELECT 1 FROM plan_usage WHERE username = ? AND ref = ?", (username, ref)).fetchone():
            return True, None
        if ref.startswith("mac:") and not lim["mac"] and lim["plan"] != "gratis":
            # Web plan: the Mac app works like Gratis (only episodes made on the Mac count)
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
