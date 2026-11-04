"""
Recordatorio al teléfono: «tu episodio empieza en una hora».

Un hilo revisa cada minuto los episodios con fecha y hora (scheduled_at, o scheduled_date a las
09:00) y, cuando faltan 60 minutos o menos, avisa una sola vez al dueño del podcast y a los
hosts adicionales a través de thePod (pod_push). La hora del episodio se guarda tal como la
escribió la persona, sin zona: se interpreta en la zona horaria de la suite (`timezone` en
~/.podpod/config.json; si no está, America/Guayaquil).

Se apaga con PREPOD_REMINDERS=0 (pruebas).
"""
from __future__ import annotations

import os
import threading
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from config import PODCASTS_DIR
from db import get_db, _ensure_column
from pod_push import notify as push_notify
from shared_config import load_shared_config

LEAD = timedelta(minutes=60)     # cuánto antes se avisa
GRACE = timedelta(minutes=30)    # si el servidor estuvo caído, no avisar de episodios ya empezados hace rato

_started = False
_lock = threading.Lock()


def _tz() -> ZoneInfo:
    name = (load_shared_config().get("timezone") or "America/Guayaquil")
    try:
        return ZoneInfo(name)
    except Exception:
        return ZoneInfo("America/Guayaquil")


def _when(row) -> datetime | None:
    s = row["scheduled_at"] or (row["scheduled_date"] + "T09:00" if row["scheduled_date"] else None)
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(str(s)[:16])
    except ValueError:
        return None
    return dt.replace(tzinfo=_tz())


def _hosts(db, slug: str) -> list[str]:
    from podcasts import _row_owner, _row_extra_hosts
    meta = db.execute("SELECT owner_username, extra_hosts FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
    if not meta:
        return []
    return [_row_owner(meta)] + _row_extra_hosts(meta)


def run_once(slug: str, now: datetime | None = None) -> int:
    """Revisa un podcast. Devuelve cuántos avisos mandó."""
    now = now or datetime.now(_tz())
    db = get_db(slug)
    sent = 0
    try:
        _ensure_column(db, "episodes", "reminded_at", "reminded_at TEXT")
        rows = db.execute(
            "SELECT id, episode_number, title, scheduled_at, scheduled_date, status FROM episodes "
            "WHERE reminded_at IS NULL AND status NOT IN ('published', 'archived') "
            "AND (scheduled_at IS NOT NULL OR scheduled_date IS NOT NULL)"
        ).fetchall()
        due = []
        for r in rows:
            at = _when(r)
            if at is None:
                continue
            if now - GRACE <= at <= now + LEAD:
                due.append((r, at))
            elif at < now - GRACE:
                # Ya pasó: se marca para no volver a mirarlo
                db.execute("UPDATE episodes SET reminded_at=? WHERE id=?", (now.isoformat(), r["id"]))
        if not due:
            db.commit()
            return 0
        who = _hosts(db, slug)
        name_row = db.execute("SELECT name FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        pod_name = (name_row["name"] if name_row and name_row["name"] else slug)
        for r, at in due:
            mins = max(0, int((at - now).total_seconds() // 60))
            when = "ahora" if mins == 0 else ("en %d min" % mins if mins < 60 else "en 1 hora")
            push_notify(who, "prePod · " + pod_name,
                        "#%s %s · empieza %s (%s)" % (r["episode_number"], r["title"] or "", when, at.strftime("%H:%M")),
                        "/pre/", tag="pre-ep-" + str(r["id"]))
            db.execute("UPDATE episodes SET reminded_at=? WHERE id=?", (now.isoformat(), r["id"]))
            sent += 1
        db.commit()
    finally:
        db.close()
    return sent


def _loop():
    while True:
        try:
            for d in sorted(PODCASTS_DIR.glob("*/")):
                if (d / "proyecto.sqlite").exists():
                    try:
                        run_once(d.name)
                    except Exception as e:  # noqa: BLE001
                        print(f"[reminders] {d.name}: {e}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"[reminders] {e}", flush=True)
        threading.Event().wait(60)


def start():
    global _started
    if os.environ.get("PREPOD_REMINDERS", "1") == "0":
        return
    with _lock:
        if _started:
            return
        _started = True
    threading.Thread(target=_loop, daemon=True, name="prepod-reminders").start()
