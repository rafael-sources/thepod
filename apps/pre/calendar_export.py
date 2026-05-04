"""
iCalendar (.ics) export of episode schedules. Produces a feed per podcast
or a single .ics for one episode. Times are interpreted as floating local
time (no TZID) — Apple/Google/Outlook all treat that correctly.
"""

import re
from datetime import datetime, timedelta

from flask import Blueprint, Response, abort

from auth import require_auth
from config import PODCASTS_DIR
from db import get_db


bp = Blueprint("calendar_export", __name__)


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _ics_escape(s: str) -> str:
    return (s or "").replace("\\", "\\\\").replace("\n", "\\n").replace(",", "\\,").replace(";", "\\;")


def _parse_local_dt(value: str):
    """Parse 'YYYY-MM-DDTHH:MM[:SS]' or 'YYYY-MM-DD' into a datetime, or None."""
    if not value:
        return None
    v = value.strip()
    # Try datetime-local first
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(v, fmt)
        except ValueError:
            continue
    # Date only — assume 09:00 local
    try:
        return datetime.strptime(v, "%Y-%m-%d").replace(hour=9, minute=0)
    except ValueError:
        return None


def _fmt_local(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%S")


def _fmt_utc(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%SZ")


def _build_event_lines(podcast_name: str, slug: str, ep_row) -> list[str]:
    starts_str = ep_row["scheduled_at"] or ep_row["scheduled_date"]
    start = _parse_local_dt(starts_str)
    if not start:
        return []
    minutes = ep_row["duration_estimate"] or 60
    try:
        end = start + timedelta(minutes=float(minutes))
    except (TypeError, ValueError):
        end = start + timedelta(minutes=60)

    title = ep_row["title"] or "Episodio"
    if ep_row["episode_number"]:
        title = f"Ep {ep_row['episode_number']}: {title}"
    summary = f"{podcast_name} · {title}"

    description_parts = [ep_row["description"] or ""]
    if ep_row["status"]:
        description_parts.append(f"[Estado: {ep_row['status']}]")
    description = "\n".join(p for p in description_parts if p).strip()

    uid = f"prepod-{slug}-ep{ep_row['id']}@podpod"
    now_utc = _fmt_utc(datetime.utcnow())

    return [
        "BEGIN:VEVENT",
        f"UID:{uid}",
        f"DTSTAMP:{now_utc}",
        f"DTSTART:{_fmt_local(start)}",
        f"DTEND:{_fmt_local(end)}",
        f"SUMMARY:{_ics_escape(summary)}",
        f"DESCRIPTION:{_ics_escape(description)}",
        "END:VEVENT",
    ]


def _wrap_calendar(slug: str, podcast_name: str, event_lines: list[str]) -> str:
    name_safe = _ics_escape(podcast_name)
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        f"PRODID:-//podpod//prepod {slug}//ES",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        f"X-WR-CALNAME:{name_safe}",
    ]
    lines.extend(event_lines)
    lines.append("END:VCALENDAR")
    # iCalendar requires CRLF line endings.
    return "\r\n".join(lines) + "\r\n"


def _ics_filename(name: str, slug: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]+", "_", name).strip("_") or slug
    return f"{safe}.ics"


@bp.get("/api/podcasts/<slug>/calendar.ics")
@require_auth
def calendar_feed(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        podcast = db.execute("SELECT name FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not podcast:
            return ("podcast no encontrado", 404)
        rows = db.execute(
            "SELECT * FROM episodes WHERE scheduled_date IS NOT NULL OR scheduled_at IS NOT NULL "
            "ORDER BY COALESCE(scheduled_at, scheduled_date)"
        ).fetchall()
    finally:
        db.close()

    events = []
    for r in rows:
        events.extend(_build_event_lines(podcast["name"], slug, r))

    body = _wrap_calendar(slug, podcast["name"], events)
    return Response(
        body,
        mimetype="text/calendar; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{_ics_filename(podcast["name"], slug)}"'},
    )


@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>.ics")
@require_auth
def episode_ics(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        podcast = db.execute("SELECT name FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        ep = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not podcast or not ep:
            return ("no encontrado", 404)
    finally:
        db.close()

    lines = _build_event_lines(podcast["name"], slug, ep)
    if not lines:
        return ("este episodio no tiene fecha programada", 400)
    body = _wrap_calendar(slug, podcast["name"], lines)
    fname = _ics_filename(f"{podcast['name']}-ep{ep['id']}", slug)
    return Response(
        body,
        mimetype="text/calendar; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
