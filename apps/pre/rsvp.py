"""
Public RSVP flow. Three routes, all unauthenticated — they identify the
guest by an opaque rsvp_token (uuid4 hex, populated in episodes.py when a
guest is created or first listed):

    GET  /rsvp/<token>            — landing page with episode info + 3 buttons
    POST /api/rsvp/<token>        — record the guest's choice (yes / no / maybe)
    GET  /rsvp/<token>/calendar.ics — public ICS so the guest can add to their calendar

This token is *separate* from `episode_guests.invite_token`, which is owned
by prodPod for the recording-room join URL.
"""

from pathlib import Path

from flask import Blueprint, abort, jsonify, render_template, request, url_for

from calendar_export import _build_event_lines, _ics_filename, _wrap_calendar
from config import PODCASTS_DIR
from db import get_db
from pod_push import notify as push_notify


bp = Blueprint("rsvp", __name__)


VALID_ACTIONS = {"yes", "no", "maybe"}


def _find_guest_by_token(token: str):
    """Linear search across podcast DBs — there's no central index of tokens
    because each podcast has its own SQLite file. With dozens of podcasts
    this is still cheap (a single indexed lookup per file)."""
    if not token or len(token) > 64:
        return None
    for entry in sorted(PODCASTS_DIR.iterdir()) if PODCASTS_DIR.exists() else []:
        if not entry.is_dir():
            continue
        slug = entry.name
        try:
            db = get_db(slug)
        except Exception:
            continue
        try:
            row = db.execute(
                """
                SELECT g.*, e.title AS ep_title, e.episode_number AS ep_number,
                       e.description AS ep_description, e.scheduled_at AS ep_scheduled_at,
                       e.scheduled_date AS ep_scheduled_date,
                       e.duration_estimate AS ep_duration_estimate, e.id AS ep_id,
                       p.name AS podcast_name, p.slug AS podcast_slug,
                       p.color_primary, p.color_secondary, p.color_accent,
                       p.color_bg, p.color_text
                FROM episode_guests g
                JOIN episodes e ON e.id = g.episode_id
                LEFT JOIN podcast_meta p ON p.slug = ?
                WHERE g.rsvp_token = ?
                LIMIT 1
                """,
                (slug, token),
            ).fetchone()
            if row:
                return slug, dict(row)
        finally:
            db.close()
    return None


@bp.get("/rsvp/<token>")
def rsvp_landing(token):
    found = _find_guest_by_token(token)
    if not found:
        return render_template("rsvp.html", error="Invitación no encontrada o vencida.",
                               guest=None, podcast=None, episode=None), 404
    slug, g = found
    podcast = {
        "name": g.get("podcast_name") or slug,
        "slug": g.get("podcast_slug") or slug,
        "color_primary": g.get("color_primary") or "#5a8bff",
        "color_secondary": g.get("color_secondary") or "#1e2a54",
        "color_accent": g.get("color_accent") or "#f4c770",
        "color_bg": g.get("color_bg") or "#0d1226",
        "color_text": g.get("color_text") or "#ffffff",
    }
    episode = {
        "id": g["ep_id"],
        "title": g["ep_title"],
        "number": g["ep_number"],
        "description": g["ep_description"] or "",
        "scheduled_at": g["ep_scheduled_at"],
        "scheduled_date": g["ep_scheduled_date"],
        "duration_estimate": g["ep_duration_estimate"],
    }
    guest = {
        "name": g["name"],
        "rsvp_status": g["rsvp_status"] or "pending",
        "rsvp_token": token,
    }
    return render_template("rsvp.html", podcast=podcast, episode=episode,
                           guest=guest, error=None)


@bp.post("/api/rsvp/<token>")
def rsvp_submit(token):
    data = request.get_json(silent=True) or {}
    action = (data.get("action") or "").strip().lower()
    if action not in VALID_ACTIONS:
        return jsonify({"error": "acción inválida"}), 400
    found = _find_guest_by_token(token)
    if not found:
        return jsonify({"error": "invitación no encontrada"}), 404
    slug, g = found
    db = get_db(slug)
    try:
        db.execute(
            "UPDATE episode_guests SET rsvp_status=? WHERE id=?",
            (action, g["id"]),
        )
        db.commit()
        try:
            meta = db.execute("SELECT owner_username, extra_hosts FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        except Exception:
            meta = None
    finally:
        db.close()
    if meta:
        from podcasts import _row_owner, _row_extra_hosts
        who = [_row_owner(meta)] + _row_extra_hosts(meta)
        label = {"yes": "confirmó", "no": "no puede", "maybe": "quizás"}.get(action, action)
        push_notify(who, "prePod · " + (g["podcast_name"] or slug),
                    (g["name"] if "name" in g.keys() and g["name"] else "Un invitado") + " " + label + " · #" + str(g["ep_number"]) + " " + (g["ep_title"] or ""),
                    "/pre/", tag="pre-rsvp-" + str(g["ep_id"]))
    return jsonify({"ok": True, "rsvp_status": action})


@bp.get("/rsvp/<token>/calendar.ics")
def rsvp_calendar(token):
    found = _find_guest_by_token(token)
    if not found:
        abort(404)
    slug, g = found
    db = get_db(slug)
    try:
        podcast = db.execute(
            "SELECT name FROM podcast_meta WHERE slug=?", (slug,)
        ).fetchone()
        ep = db.execute(
            "SELECT * FROM episodes WHERE id=?", (g["ep_id"],)
        ).fetchone()
    finally:
        db.close()
    if not podcast or not ep:
        abort(404)
    event_lines = _build_event_lines(podcast["name"], slug, ep)
    if not event_lines:
        abort(400)
    body = _wrap_calendar(slug, podcast["name"], event_lines)
    fname = _ics_filename(f"{podcast['name']}-ep{ep['id']}", slug)
    from flask import Response
    return Response(
        body,
        mimetype="text/calendar; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )


def build_episode_ics_bytes(slug: str, ep_id: int) -> bytes | None:
    """Return the ICS body for a single episode as bytes, or None if the
    episode has no scheduled date. Used by the email helper to attach the
    calendar invite directly without going through HTTP.
    """
    db = get_db(slug)
    try:
        podcast = db.execute("SELECT name FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        ep = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
    finally:
        db.close()
    if not podcast or not ep:
        return None
    event_lines = _build_event_lines(podcast["name"], slug, ep)
    if not event_lines:
        return None
    body = _wrap_calendar(slug, podcast["name"], event_lines)
    return body.encode("utf-8")
