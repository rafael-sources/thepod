"""
Episodes, ideas (with voting), and script sections.
All endpoints scoped under `/api/podcasts/<slug>/`.
"""

import json as _json
import logging
import threading

from flask import Blueprint, abort, jsonify, request, session

from auth import require_auth
from config import PODCASTS_DIR
from db import get_db


bp = Blueprint("episodes", __name__)

EPISODE_STATUSES = ("idea", "planning", "scripted", "recorded", "published", "archived")
IDEA_STATUSES = ("proposed", "accepted", "rejected")


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _serialize_episode(row):
    keys = row.keys()
    prod_meta = None
    if "production_meta" in keys and row["production_meta"]:
        try:
            prod_meta = _json.loads(row["production_meta"])
        except (TypeError, ValueError):
            prod_meta = None
    return {
        "id": row["id"],
        "episode_number": row["episode_number"],
        "title": row["title"],
        "description": row["description"] or "",
        "status": row["status"],
        "scheduled_date": row["scheduled_date"],
        "scheduled_at": row["scheduled_at"] if "scheduled_at" in keys else None,
        "duration_estimate": row["duration_estimate"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "landing_position": row["landing_position"] if "landing_position" in keys else None,
        "production_status": row["production_status"] if "production_status" in keys else None,
        "production_meta": prod_meta,
        "production_updated_at": row["production_updated_at"] if "production_updated_at" in keys else None,
        "ai_summary": row["ai_summary"] if "ai_summary" in keys else None,
        "ai_highlights": _json.loads(row["ai_highlights"]) if ("ai_highlights" in keys and row["ai_highlights"]) else [],
        "ai_notes_edited": bool(row["ai_notes_edited"]) if "ai_notes_edited" in keys else False,
        "ai_notes_synced_at": row["ai_notes_synced_at"] if "ai_notes_synced_at" in keys else None,
        "media_url": row["media_url"] if "media_url" in keys else None,
    }


def _serialize_idea(row, voted=False):
    return {
        "id": row["id"],
        "episode_id": row["episode_id"],
        "content": row["content"],
        "author": row["author"],
        "status": row["status"],
        "votes": row["votes"] or 0,
        "voted_by_me": bool(voted),
        "created_at": row["created_at"],
    }


def _serialize_section(row):
    return {
        "id": row["id"],
        "episode_id": row["episode_id"],
        "position": row["position"],
        "speaker": row["speaker"] or "",
        "content": row["content"] or "",
        "estimated_duration": row["estimated_duration"],
        "notes": row["notes"] or "",
        "created_at": row["created_at"],
        # Teleprompter (solo las secciones que lo usan; quién lo lee = speaker)
        "tp_enabled": bool(_rowget(row, "tp_enabled", 0)),
        "tp_offset_seconds": _rowget(row, "tp_offset_seconds", None),
        "tp_speed": _rowget(row, "tp_speed", "normal") or "normal",
        "tp_size": _rowget(row, "tp_size", "half") or "half",
        "tp_speaker": _rowget(row, "tp_speaker", None) or "",
    }


def _rowget(row, key, default):
    try:
        return row[key]
    except (IndexError, KeyError):
        return default


def _current_user():
    return session.get("username") or "anon"


def _sync_ai_notes(slug: str, ep_id: int, shared_project_id: str):
    """Fetch show notes from postPod if available. Non-blocking, best-effort."""
    from shared_config import load_shared_config
    cfg = load_shared_config()
    postpod_url = cfg.get("postpod_url")
    if not postpod_url or not shared_project_id:
        return

    from integrations import _http_json
    status_code, status_data = _http_json(
        "GET",
        f"{postpod_url}/api/integrations/status?shared_project_id={shared_project_id}&source_episode_id={ep_id}",
        headers={"X-PodPod-Secret": cfg.get("integration_secret", "")},
    )
    if status_code != 200 or not status_data or not status_data.get("slug"):
        return

    postpod_slug = status_data["slug"]
    code, data = _http_json(
        "GET",
        f"{postpod_url}/api/projects/{postpod_slug}/ai/show-notes",
        headers={"X-PodPod-Secret": cfg.get("integration_secret", "")},
    )
    if code != 200 or not data or not data.get("summary"):
        return

    db = get_db(slug)
    try:
        row = db.execute("SELECT ai_notes_edited FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not row:
            return
        if row["ai_notes_edited"]:
            return
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        db.execute(
            "UPDATE episodes SET ai_summary=?, ai_highlights=?, ai_notes_synced_at=? WHERE id=?",
            (data["summary"], _json.dumps(data.get("highlights", []), ensure_ascii=False), now, ep_id),
        )
        db.commit()
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Episodes
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/episodes")
@require_auth
def list_episodes(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM episodes ORDER BY episode_number, id"
        ).fetchall()
        return jsonify([_serialize_episode(r) for r in rows])
    finally:
        db.close()


def _auto_populate_team_as_guests(db, ep_id):
    """Copy team_members into episode_guests for a new episode so hosts
    and recurring co-hosts appear in the roster with their social handles."""
    import uuid as _uuid
    team = db.execute(
        "SELECT name, role, bio, social_twitter, social_instagram, "
        "social_youtube, social_tiktok FROM team_members ORDER BY position, id"
    ).fetchall()
    for m in team:
        guest_role = "host" if (m["role"] or "").lower() in ("host", "conductor", "presentador") else "co-host"
        db.execute(
            "INSERT INTO episode_guests "
            "(episode_id, name, role, bio, rsvp_token, rsvp_status, "
            "social_instagram, social_twitter, social_youtube, social_tiktok) "
            "VALUES (?, ?, ?, ?, ?, 'yes', ?, ?, ?, ?)",
            (
                ep_id,
                m["name"],
                guest_role,
                m["bio"] or None,
                _uuid.uuid4().hex,
                m["social_instagram"],
                m["social_twitter"],
                m["social_youtube"] if "social_youtube" in m.keys() else None,
                m["social_tiktok"] if "social_tiktok" in m.keys() else None,
            ),
        )


@bp.post("/api/podcasts/<slug>/episodes")
@require_auth
def create_episode(slug):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    title = (data.get("title") or "").strip()
    if not title:
        return jsonify({"error": "title requerido"}), 400

    db = get_db(slug)
    try:
        # Episode number: caller can request a specific one, otherwise next free.
        max_row = db.execute("SELECT COALESCE(MAX(episode_number), 0) AS n FROM episodes").fetchone()
        next_number = (max_row["n"] or 0) + 1
        requested = data.get("episode_number")
        if requested is not None:
            try: requested = int(requested)
            except (TypeError, ValueError): requested = None
            if requested and requested >= 1:
                clash = db.execute(
                    "SELECT id FROM episodes WHERE episode_number=?", (requested,)
                ).fetchone()
                if clash:
                    return jsonify({"error": f"el episodio #{requested} ya existe"}), 409
                next_number = requested
        status = data.get("status") or "idea"
        if status not in EPISODE_STATUSES:
            return jsonify({"error": f"status inválido: {status}"}), 400

        scheduled_at = data.get("scheduled_at")
        scheduled_date = data.get("scheduled_date") or (
            scheduled_at[:10] if isinstance(scheduled_at, str) and len(scheduled_at) >= 10 else None
        )
        cur = db.execute(
            "INSERT INTO episodes (episode_number, title, description, status, scheduled_date, scheduled_at, duration_estimate) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                next_number,
                title,
                data.get("description") or "",
                status,
                scheduled_date,
                scheduled_at,
                data.get("duration_estimate"),
            ),
        )
        new_ep_id = cur.lastrowid

        # Apply a show template (rundown blocks + base script sections).
        # Resolution order:
        #   1. data["template_id"] if explicitly given (None / 0 / "none" → no template)
        #   2. else the podcast's default template, if any
        # Caller can opt out by passing template_id=null/0/"none".
        from templates_api import copy_template_into_episode  # local import: avoid circular

        tpl_id = None
        if "template_id" in data:
            raw = data.get("template_id")
            if raw not in (None, 0, "0", "", "none", "null", False):
                try:
                    tpl_id = int(raw)
                except (TypeError, ValueError):
                    tpl_id = None
        else:
            default_row = db.execute(
                "SELECT id FROM templates WHERE is_default=1 LIMIT 1"
            ).fetchone()
            if default_row:
                tpl_id = default_row["id"]

        if tpl_id is not None:
            tpl_exists = db.execute(
                "SELECT id FROM templates WHERE id=?", (tpl_id,)
            ).fetchone()
            if tpl_exists:
                copy_template_into_episode(db, tpl_id, new_ep_id)

        _auto_populate_team_as_guests(db, new_ep_id)
        db.commit()
        row = db.execute("SELECT * FROM episodes WHERE id=?", (new_ep_id,)).fetchone()
        return jsonify(_serialize_episode(row)), 201
    finally:
        db.close()


@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>")
@require_auth
def get_episode(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not row:
            return jsonify({"error": "episodio no encontrado"}), 404
        # Trigger background AI notes sync if linked to postPod
        if row and "production_meta" in row.keys() and row["production_meta"]:
            try:
                pm = _json.loads(row["production_meta"])
                spid = pm.get("shared_project_id")
                if spid:
                    threading.Thread(target=_sync_ai_notes, args=(slug, ep_id, spid), daemon=True).start()
            except (TypeError, ValueError):
                pass
        return jsonify(_serialize_episode(row))
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/episodes/<int:ep_id>")
@require_auth
def update_episode(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    allowed = {"title", "description", "scheduled_date", "scheduled_at", "duration_estimate", "status", "episode_number", "landing_position"}
    updates = {k: v for k, v in data.items() if k in allowed}
    if "status" in updates and updates["status"] not in EPISODE_STATUSES:
        return jsonify({"error": f"status inválido: {updates['status']}"}), 400
    if not updates:
        return jsonify({"error": "nada para actualizar"}), 400

    db = get_db(slug)
    try:
        existing = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not existing:
            return jsonify({"error": "episodio no encontrado"}), 404
        # Block episode_number collisions: only one episode can hold a given
        # number (excluding the one being edited).
        if "episode_number" in updates and updates["episode_number"] is not None:
            try:
                n = int(updates["episode_number"])
            except (TypeError, ValueError):
                return jsonify({"error": "episode_number inválido"}), 400
            if n < 1:
                return jsonify({"error": "episode_number debe ser ≥ 1"}), 400
            updates["episode_number"] = n
            clash = db.execute(
                "SELECT id FROM episodes WHERE episode_number=? AND id != ?",
                (n, ep_id),
            ).fetchone()
            if clash:
                return jsonify({"error": f"ya existe un episodio con número #{n}"}), 409
        cols = ", ".join(f"{k}=?" for k in updates) + ", updated_at=datetime('now')"
        params = list(updates.values()) + [ep_id]
        db.execute(f"UPDATE episodes SET {cols} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
        return jsonify(_serialize_episode(row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/episodes/<int:ep_id>")
@require_auth
def delete_episode(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not row:
            return jsonify({"error": "episodio no encontrado"}), 404

        podcast = db.execute(
            "SELECT shared_project_id FROM podcast_meta WHERE slug=?", (slug,)
        ).fetchone()
        spid = podcast["shared_project_id"] if podcast else None

        db.execute("DELETE FROM episodes WHERE id=?", (ep_id,))
        db.commit()
    finally:
        db.close()

    if spid:
        threading.Thread(
            target=_cascade_delete_episode,
            args=(slug, ep_id, spid),
            daemon=True,
        ).start()

    return jsonify({"ok": True})


def _cascade_delete_episode(source_slug, source_episode_id, shared_project_id):
    from integrations import _http_json
    from shared_config import load_shared_config
    cfg = load_shared_config()
    secret = cfg.get("integration_secret", "")
    headers = {"X-PodPod-Secret": secret}
    body = {
        "source_slug": source_slug,
        "source_episode_id": source_episode_id,
        "shared_project_id": shared_project_id,
    }

    for label, key in [("prodPod", "prodpod_url"), ("postPod", "postpod_url")]:
        base = (cfg.get(key) or "").rstrip("/")
        if not base:
            continue
        try:
            _http_json(
                "POST",
                f"{base}/api/integrations/prepod/delete-episode",
                body=body,
                headers=headers,
                timeout=10,
            )
        except Exception as e:
            logging.warning("Cascade delete to %s failed: %s", label, e)


# ---------------------------------------------------------------------------
# Ideas + voting
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/ideas")
@require_auth
def list_ideas(slug, ep_id):
    _ensure_podcast(slug)
    user = _current_user()
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM ideas WHERE episode_id=? ORDER BY votes DESC, created_at DESC",
            (ep_id,),
        ).fetchall()
        voted_rows = db.execute(
            "SELECT idea_id FROM idea_votes WHERE username=?", (user,)
        ).fetchall()
        voted = {r["idea_id"] for r in voted_rows}
        return jsonify([_serialize_idea(r, r["id"] in voted) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/ideas")
@require_auth
def create_idea(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    content = (data.get("content") or "").strip()
    if not content:
        return jsonify({"error": "content requerido"}), 400
    if len(content) > 500:
        return jsonify({"error": "content supera 500 caracteres"}), 400

    db = get_db(slug)
    try:
        ep = db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404
        cur = db.execute(
            "INSERT INTO ideas (episode_id, content, author) VALUES (?, ?, ?)",
            (ep_id, content, _current_user()),
        )
        db.commit()
        row = db.execute("SELECT * FROM ideas WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_idea(row, False)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/ideas/<int:idea_id>")
@require_auth
def update_idea(slug, idea_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    allowed = {"content", "status"}
    updates = {k: v for k, v in data.items() if k in allowed}
    if "status" in updates and updates["status"] not in IDEA_STATUSES:
        return jsonify({"error": f"status inválido: {updates['status']}"}), 400
    if "content" in updates:
        updates["content"] = (updates["content"] or "").strip()
        if len(updates["content"]) > 500:
            return jsonify({"error": "content supera 500 caracteres"}), 400
    if not updates:
        return jsonify({"error": "nada para actualizar"}), 400

    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM ideas WHERE id=?", (idea_id,)).fetchone()
        if not row:
            return jsonify({"error": "idea no encontrada"}), 404
        cols = ", ".join(f"{k}=?" for k in updates)
        params = list(updates.values()) + [idea_id]
        db.execute(f"UPDATE ideas SET {cols} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM ideas WHERE id=?", (idea_id,)).fetchone()
        voted = bool(db.execute(
            "SELECT 1 FROM idea_votes WHERE idea_id=? AND username=?",
            (idea_id, _current_user()),
        ).fetchone())
        return jsonify(_serialize_idea(row, voted))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/ideas/<int:idea_id>")
@require_auth
def delete_idea(slug, idea_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM ideas WHERE id=?", (idea_id,)).fetchone()
        if not row:
            return jsonify({"error": "idea no encontrada"}), 404
        db.execute("DELETE FROM ideas WHERE id=?", (idea_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/ideas/<int:idea_id>/vote")
@require_auth
def vote_idea(slug, idea_id):
    _ensure_podcast(slug)
    user = _current_user()
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM ideas WHERE id=?", (idea_id,)).fetchone()
        if not row:
            return jsonify({"error": "idea no encontrada"}), 404
        try:
            db.execute(
                "INSERT INTO idea_votes (idea_id, username) VALUES (?, ?)",
                (idea_id, user),
            )
        except Exception:
            # Already voted — idempotent
            pass
        # Recalc vote count
        n = db.execute(
            "SELECT COUNT(*) AS n FROM idea_votes WHERE idea_id=?", (idea_id,)
        ).fetchone()["n"]
        db.execute("UPDATE ideas SET votes=? WHERE id=?", (n, idea_id))
        db.commit()
        return jsonify({"votes": n, "voted_by_me": True})
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/ideas/<int:idea_id>/vote")
@require_auth
def unvote_idea(slug, idea_id):
    _ensure_podcast(slug)
    user = _current_user()
    db = get_db(slug)
    try:
        db.execute(
            "DELETE FROM idea_votes WHERE idea_id=? AND username=?",
            (idea_id, user),
        )
        n = db.execute(
            "SELECT COUNT(*) AS n FROM idea_votes WHERE idea_id=?", (idea_id,)
        ).fetchone()["n"]
        db.execute("UPDATE ideas SET votes=? WHERE id=?", (n, idea_id))
        db.commit()
        return jsonify({"votes": n, "voted_by_me": False})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Script sections
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/script")
@require_auth
def list_script(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM script_sections WHERE episode_id=? ORDER BY position, id",
            (ep_id,),
        ).fetchall()
        return jsonify([_serialize_section(r) for r in rows])
    finally:
        db.close()


def _normalize_script_positions(db, ep_id):
    rows = db.execute(
        "SELECT id FROM script_sections WHERE episode_id=? ORDER BY position, id",
        (ep_id,),
    ).fetchall()
    for i, r in enumerate(rows):
        db.execute("UPDATE script_sections SET position=? WHERE id=?", (i, r["id"]))


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/script")
@require_auth
def add_script_section(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        ep = db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404
        n = db.execute(
            "SELECT COUNT(*) AS n FROM script_sections WHERE episode_id=?", (ep_id,)
        ).fetchone()["n"]
        cur = db.execute(
            "INSERT INTO script_sections (episode_id, position, speaker, content, estimated_duration, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                ep_id, n,
                (data.get("speaker") or "").strip(),
                data.get("content") or "",
                data.get("estimated_duration"),
                data.get("notes") or "",
            ),
        )
        db.commit()
        row = db.execute(
            "SELECT * FROM script_sections WHERE id=?", (cur.lastrowid,)
        ).fetchone()
        return jsonify(_serialize_section(row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/script-sections/<int:sec_id>")
@require_auth
def update_script_section(slug, sec_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        existing = db.execute(
            "SELECT * FROM script_sections WHERE id=?", (sec_id,)
        ).fetchone()
        if not existing:
            return jsonify({"error": "sección no encontrada"}), 404

        ep_id = existing["episode_id"]

        # Reorder first if position changed
        if "position" in data and data["position"] is not None:
            new_pos = max(0, int(data["position"]))
            old_pos = existing["position"]
            if new_pos != old_pos:
                n = db.execute(
                    "SELECT COUNT(*) AS n FROM script_sections WHERE episode_id=?",
                    (ep_id,),
                ).fetchone()["n"]
                new_pos = min(new_pos, n - 1)
                # Park target out of range
                db.execute("UPDATE script_sections SET position=-1 WHERE id=?", (sec_id,))
                if new_pos > old_pos:
                    db.execute(
                        "UPDATE script_sections SET position=position-1 "
                        "WHERE episode_id=? AND position > ? AND position <= ?",
                        (ep_id, old_pos, new_pos),
                    )
                else:
                    db.execute(
                        "UPDATE script_sections SET position=position+1 "
                        "WHERE episode_id=? AND position >= ? AND position < ?",
                        (ep_id, new_pos, old_pos),
                    )
                db.execute(
                    "UPDATE script_sections SET position=? WHERE id=?",
                    (new_pos, sec_id),
                )
                _normalize_script_positions(db, ep_id)

        other_updates = {}
        for k in ("speaker", "content", "estimated_duration", "notes", "tp_offset_seconds", "tp_speaker"):
            if k in data:
                other_updates[k] = data[k]
        if "tp_enabled" in data:
            other_updates["tp_enabled"] = 1 if data["tp_enabled"] else 0
        if data.get("tp_speed") in ("slow", "normal", "fast"):
            other_updates["tp_speed"] = data["tp_speed"]
        if data.get("tp_size") in ("quarter", "half", "full"):
            other_updates["tp_size"] = data["tp_size"]
        if other_updates:
            cols = ", ".join(f"{k}=?" for k in other_updates)
            params = list(other_updates.values()) + [sec_id]
            db.execute(f"UPDATE script_sections SET {cols} WHERE id=?", params)

        db.commit()
        row = db.execute(
            "SELECT * FROM script_sections WHERE id=?", (sec_id,)
        ).fetchone()
        return jsonify(_serialize_section(row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/script-sections/<int:sec_id>")
@require_auth
def delete_script_section(slug, sec_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT id, episode_id FROM script_sections WHERE id=?", (sec_id,)
        ).fetchone()
        if not row:
            return jsonify({"error": "sección no encontrada"}), 404
        ep_id = row["episode_id"]
        db.execute("DELETE FROM script_sections WHERE id=?", (sec_id,))
        _normalize_script_positions(db, ep_id)
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Episode guests (roster)
# ---------------------------------------------------------------------------

GUEST_ROLES = ("host", "co-host", "guest")
RSVP_STATUSES = ("pending", "yes", "no", "maybe")


def _serialize_guest(row):
    keys = row.keys()
    rsvp_token = row["rsvp_token"] if "rsvp_token" in keys else None
    return {
        "id": row["id"],
        "episode_id": row["episode_id"],
        "name": row["name"],
        "email": row["email"] or "",
        "role": row["role"],
        "bio": row["bio"] or "",
        "rsvp_status": row["rsvp_status"],
        "invite_url": row["invite_url"] or "",
        "invite_token": row["invite_token"] or "",
        "rsvp_token": rsvp_token or "",
        "rsvp_url": f"/rsvp/{rsvp_token}" if rsvp_token else "",
        "social_instagram": row["social_instagram"] if "social_instagram" in keys else "",
        "social_twitter": row["social_twitter"] if "social_twitter" in keys else "",
        "social_youtube": row["social_youtube"] if "social_youtube" in keys else "",
        "social_tiktok": row["social_tiktok"] if "social_tiktok" in keys else "",
        "photo_filename": row["photo_filename"] if "photo_filename" in keys else None,
        "created_at": row["created_at"],
    }


def _ensure_rsvp_tokens(db, ep_id):
    """Backfill rsvp_token for any guest in this episode that doesn't have
    one yet. Idempotent: rows that already have a token are left alone."""
    import uuid as _uuid
    missing = db.execute(
        "SELECT id FROM episode_guests WHERE episode_id=? AND (rsvp_token IS NULL OR rsvp_token='')",
        (ep_id,),
    ).fetchall()
    for r in missing:
        db.execute(
            "UPDATE episode_guests SET rsvp_token=? WHERE id=?",
            (_uuid.uuid4().hex, r["id"]),
        )
    if missing:
        db.commit()


@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/guests")
@require_auth
def list_guests(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        _ensure_rsvp_tokens(db, ep_id)
        rows = db.execute(
            "SELECT * FROM episode_guests WHERE episode_id=? ORDER BY id",
            (ep_id,),
        ).fetchall()
        return jsonify([_serialize_guest(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/guests")
@require_auth
def create_guest(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name requerido"}), 400
    role = (data.get("role") or "guest").strip()
    if role not in GUEST_ROLES:
        return jsonify({"error": f"role inválido: {role}"}), 400
    email = (data.get("email") or "").strip() or None
    bio = (data.get("bio") or "").strip() or None
    social_ig = (data.get("social_instagram") or "").strip() or None
    social_tw = (data.get("social_twitter") or "").strip() or None
    social_yt = (data.get("social_youtube") or "").strip() or None
    social_tk = (data.get("social_tiktok") or "").strip() or None

    import uuid as _uuid
    db = get_db(slug)
    try:
        ep = db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404
        cur = db.execute(
            "INSERT INTO episode_guests (episode_id, name, email, role, bio, rsvp_token, "
            "social_instagram, social_twitter, social_youtube, social_tiktok) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (ep_id, name, email, role, bio, _uuid.uuid4().hex,
             social_ig, social_tw, social_yt, social_tk),
        )
        db.commit()
        row = db.execute("SELECT * FROM episode_guests WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_guest(row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/guests/<int:guest_id>")
@require_auth
def update_guest(slug, guest_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM episode_guests WHERE id=?", (guest_id,)).fetchone()
        if not row:
            return jsonify({"error": "invitado no encontrado"}), 404
        updates, params = [], []
        for f in ("name", "email", "bio", "social_instagram", "social_twitter",
                  "social_youtube", "social_tiktok"):
            if f in data:
                updates.append(f"{f}=?")
                params.append((data[f] or "").strip() or None)
        if "role" in data:
            r = (data["role"] or "").strip()
            if r not in GUEST_ROLES:
                return jsonify({"error": f"role inválido: {r}"}), 400
            updates.append("role=?")
            params.append(r)
        if "rsvp_status" in data:
            s = (data["rsvp_status"] or "").strip()
            if s not in RSVP_STATUSES:
                return jsonify({"error": f"rsvp_status inválido: {s}"}), 400
            updates.append("rsvp_status=?")
            params.append(s)
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(guest_id)
        db.execute(f"UPDATE episode_guests SET {', '.join(updates)} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM episode_guests WHERE id=?", (guest_id,)).fetchone()
        return jsonify(_serialize_guest(row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/guests/<int:guest_id>")
@require_auth
def delete_guest(slug, guest_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        db.execute("DELETE FROM episode_guests WHERE id=?", (guest_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/guests/<int:guest_id>/send-rsvp")
@require_auth
def send_rsvp_invite(slug, guest_id):
    """Send the RSVP invitation by email if SMTP is configured. If not, the
    response carries `ok: False, reason: 'no_smtp'` plus a public RSVP URL
    so the UI can show a copy-link fallback. Always returns 200 with a
    structured body — the UI branches on `ok`/`reason`."""
    _ensure_podcast(slug)
    import uuid as _uuid

    db = get_db(slug)
    try:
        row = db.execute(
            """
            SELECT g.*, e.title AS ep_title, e.episode_number AS ep_number,
                   e.description AS ep_description, e.scheduled_at AS ep_scheduled_at,
                   e.scheduled_date AS ep_scheduled_date,
                   e.duration_estimate AS ep_duration_estimate, e.id AS ep_id,
                   p.name AS podcast_name
            FROM episode_guests g
            JOIN episodes e ON e.id = g.episode_id
            LEFT JOIN podcast_meta p ON p.slug = ?
            WHERE g.id=?
            """,
            (slug, guest_id),
        ).fetchone()
        if not row:
            return jsonify({"error": "invitado no encontrado"}), 404

        # Lazy-create the rsvp_token if missing (older rows from before the
        # column existed, or any guest somehow inserted without one).
        rsvp_token = row["rsvp_token"]
        if not rsvp_token:
            rsvp_token = _uuid.uuid4().hex
            db.execute(
                "UPDATE episode_guests SET rsvp_token=? WHERE id=?",
                (rsvp_token, guest_id),
            )
            db.commit()
    finally:
        db.close()

    if not (row["email"] or "").strip():
        return jsonify({"error": "el invitado no tiene email"}), 400

    from email_helper import send_rsvp_email
    from rsvp import build_episode_ics_bytes
    ics = build_episode_ics_bytes(slug, row["ep_id"])
    result = send_rsvp_email(
        to_email=row["email"],
        to_name=row["name"] or "",
        podcast_name=row["podcast_name"] or slug,
        episode_title=row["ep_title"] or "",
        episode_number=row["ep_number"],
        scheduled_at=row["ep_scheduled_at"],
        scheduled_date=row["ep_scheduled_date"],
        duration_estimate=row["ep_duration_estimate"],
        description=row["ep_description"] or "",
        rsvp_token=rsvp_token,
        ics_bytes=ics,
    )
    return jsonify(result)


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/send-pre-recording")
@require_auth
def send_pre_recording(slug, ep_id):
    """Send preparation email to one guest (guest_id in body) or all guests
    of this episode (guest_id omitted / null).  Returns a list of per-guest
    results so the UI can show which ones succeeded."""
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    target_guest_id = data.get("guest_id")

    db = get_db(slug)
    try:
        ep = db.execute(
            """SELECT e.*, p.name AS podcast_name
               FROM episodes e
               LEFT JOIN podcast_meta p ON p.slug = ?
               WHERE e.id = ?""",
            (slug, ep_id),
        ).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404

        if target_guest_id:
            guests = db.execute(
                "SELECT * FROM episode_guests WHERE id=? AND episode_id=?",
                (target_guest_id, ep_id),
            ).fetchall()
        else:
            guests = db.execute(
                "SELECT * FROM episode_guests WHERE episode_id=? AND email IS NOT NULL AND email != ''",
                (ep_id,),
            ).fetchall()

        if not guests:
            return jsonify({"error": "no hay invitados con email"}), 400

        blocks = db.execute(
            "SELECT kind, title, duration_estimate FROM episode_blocks "
            "WHERE episode_id=? ORDER BY position, id",
            (ep_id,),
        ).fetchall()
        rundown = [{"kind": b["kind"], "title": b["title"], "duration_estimate": b["duration_estimate"]} for b in blocks]
    finally:
        db.close()

    from email_helper import send_pre_recording_email
    from rsvp import build_episode_ics_bytes
    ics = build_episode_ics_bytes(slug, ep_id)

    results = []
    for g in guests:
        email = (g["email"] or "").strip()
        if not email:
            results.append({"guest_id": g["id"], "name": g["name"], "ok": False, "reason": "no_email"})
            continue
        rec_url = (g["invite_url"] or "").strip() or None
        r = send_pre_recording_email(
            to_email=email,
            to_name=g["name"] or "",
            podcast_name=ep["podcast_name"] or slug,
            episode_title=ep["title"] or "",
            episode_number=ep["episode_number"],
            scheduled_at=ep["scheduled_at"] if "scheduled_at" in ep.keys() else None,
            scheduled_date=ep["scheduled_date"],
            duration_estimate=ep["duration_estimate"],
            recording_url=rec_url,
            rundown=rundown,
            ics_bytes=ics,
        )
        r["guest_id"] = g["id"]
        r["name"] = g["name"]
        results.append(r)

    ok_count = sum(1 for r in results if r.get("ok"))
    return jsonify({"results": results, "sent": ok_count, "total": len(results)})


# ---------------------------------------------------------------------------
# Episode rundown blocks (intro / segment / sponsor / outro …)
# ---------------------------------------------------------------------------

BLOCK_KINDS = ("intro", "segment", "interview", "sponsor", "break", "outro", "custom")


def _serialize_block(row):
    keys = row.keys()
    return {
        "id": row["id"],
        "episode_id": row["episode_id"],
        "position": row["position"],
        "kind": row["kind"],
        "title": row["title"] or "",
        "duration_estimate": row["duration_estimate"],
        "notes": row["notes"] or "",
        "sponsor_id": row["sponsor_id"] if "sponsor_id" in keys else None,
        "planned_offset_seconds": row["planned_offset_seconds"] if "planned_offset_seconds" in keys else None,
        "created_at": row["created_at"],
    }


def _normalize_block_positions(db, ep_id):
    rows = db.execute(
        "SELECT id FROM episode_blocks WHERE episode_id=? ORDER BY position, id",
        (ep_id,),
    ).fetchall()
    for i, r in enumerate(rows):
        db.execute("UPDATE episode_blocks SET position=? WHERE id=?", (i, r["id"]))


@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/blocks")
@require_auth
def list_blocks(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM episode_blocks WHERE episode_id=? ORDER BY position, id",
            (ep_id,),
        ).fetchall()
        return jsonify([_serialize_block(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/blocks")
@require_auth
def create_block(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    kind = (data.get("kind") or "segment").strip()
    if kind not in BLOCK_KINDS:
        return jsonify({"error": f"kind inválido: {kind}"}), 400
    title = (data.get("title") or "").strip()
    duration = data.get("duration_estimate")
    notes = (data.get("notes") or "").strip() or None

    db = get_db(slug)
    try:
        ep = db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404
        max_pos = db.execute(
            "SELECT COALESCE(MAX(position), -1) AS m FROM episode_blocks WHERE episode_id=?",
            (ep_id,),
        ).fetchone()["m"]
        cur = db.execute(
            "INSERT INTO episode_blocks (episode_id, position, kind, title, duration_estimate, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (ep_id, max_pos + 1, kind, title, duration, notes),
        )
        db.commit()
        row = db.execute("SELECT * FROM episode_blocks WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_block(row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/blocks/<int:block_id>")
@require_auth
def update_block(slug, block_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM episode_blocks WHERE id=?", (block_id,)).fetchone()
        if not row:
            return jsonify({"error": "bloque no encontrado"}), 404
        updates, params = [], []
        if "kind" in data:
            k = (data["kind"] or "").strip()
            if k not in BLOCK_KINDS:
                return jsonify({"error": f"kind inválido: {k}"}), 400
            updates.append("kind=?"); params.append(k)
        if "title" in data:
            updates.append("title=?"); params.append((data["title"] or "").strip())
        if "duration_estimate" in data:
            v = data["duration_estimate"]
            updates.append("duration_estimate=?"); params.append(v if v in (None, "") else float(v) or None)
        if "notes" in data:
            updates.append("notes=?"); params.append((data["notes"] or "").strip() or None)
        if "planned_offset_seconds" in data:
            v = data["planned_offset_seconds"]
            updates.append("planned_offset_seconds=?"); params.append(int(v) if v not in (None, "", False) else None)
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(block_id)
        db.execute(f"UPDATE episode_blocks SET {', '.join(updates)} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM episode_blocks WHERE id=?", (block_id,)).fetchone()
        return jsonify(_serialize_block(row))
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/blocks/reorder")
@require_auth
def reorder_blocks(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    order = data.get("order") or []
    if not isinstance(order, list):
        return jsonify({"error": "order debe ser lista de IDs"}), 400
    db = get_db(slug)
    try:
        for i, bid in enumerate(order):
            db.execute(
                "UPDATE episode_blocks SET position=? WHERE id=? AND episode_id=?",
                (i, int(bid), ep_id),
            )
        _normalize_block_positions(db, ep_id)
        db.commit()
        rows = db.execute(
            "SELECT * FROM episode_blocks WHERE episode_id=? ORDER BY position, id",
            (ep_id,),
        ).fetchall()
        return jsonify([_serialize_block(r) for r in rows])
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/blocks/<int:block_id>")
@require_auth
def delete_block(slug, block_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT episode_id FROM episode_blocks WHERE id=?", (block_id,)).fetchone()
        if not row:
            return jsonify({"error": "bloque no encontrado"}), 404
        ep_id = row["episode_id"]
        db.execute("DELETE FROM episode_blocks WHERE id=?", (block_id,))
        _normalize_block_positions(db, ep_id)
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Show notes generator: assembles a ready-to-paste description for
# Spotify/Apple/YouTube from the episode's existing data:
#   title + description + rundown blocks (chapters) + guests + external links.
# Returns both the formatted text and the structured pieces so the UI can
# offer per-platform variants in the future.
# ---------------------------------------------------------------------------

# Cosmetic labels per platform — used as the link list bullet prefix.
_LINK_PLATFORM_LABELS = {
    "spotify": "Spotify",
    "apple": "Apple Podcasts",
    "apple_podcasts": "Apple Podcasts",
    "youtube": "YouTube",
    "amazon": "Amazon Music",
    "google": "Google Podcasts",
    "rss": "RSS",
    "web": "Web",
}


def _fmt_offset(seconds: float) -> str:
    """0:00, 12:34, 1:02:03 — YouTube-friendly.

    YouTube requires the first chapter timestamp to be "0:00" (not "00:00")
    for chapter parsing to kick in, and any chapter at or after 1 hour to
    use H:MM:SS. We follow that convention for all platforms — Spotify and
    Apple accept it.
    """
    s = max(0, int(round(seconds or 0)))
    h, rem = divmod(s, 3600)
    m, ss = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{ss:02d}"
    return f"{m}:{ss:02d}"


def _build_show_notes_text(ep_row, blocks, guests, links) -> str:
    parts = []
    title = (ep_row["title"] or "").strip()
    if title:
        parts.append(title)
        parts.append("")  # blank line under title

    desc = (ep_row["description"] or "").strip()
    if desc:
        parts.append(desc)
        parts.append("")

    # Chapters: only emit the section if we have blocks with usable durations
    # (at least one with a non-zero duration_estimate). Cumulative offsets
    # start at 0 — first chapter is always "0:00" per YouTube convention.
    chapters = []
    if blocks:
        offset = 0.0
        for b in blocks:
            label = (b["title"] or "").strip() or _block_kind_label(b["kind"])
            chapters.append({"offset_seconds": offset, "label": label})
            mins = float(b["duration_estimate"] or 0)
            offset += mins * 60.0
    has_real_durations = any((b["duration_estimate"] or 0) > 0 for b in blocks)
    if chapters and has_real_durations:
        parts.append("Capítulos")
        for ch in chapters:
            parts.append(f"{_fmt_offset(ch['offset_seconds'])} {ch['label']}")
        parts.append("")

    # Guests (skip hosts — they don't belong in the per-episode show notes;
    # the show host is implicit).
    real_guests = [g for g in guests if (g["role"] or "guest") == "guest"]
    if real_guests:
        parts.append("Invitados")
        for g in real_guests:
            line = f"• {g['name']}"
            bio = (g["bio"] or "").strip()
            if bio:
                line += f" — {bio}"
            parts.append(line)
        parts.append("")

    if links:
        parts.append("Escuchá en")
        for ln in links:
            label = _LINK_PLATFORM_LABELS.get(
                (ln["platform"] or "").lower(), (ln["platform"] or "").title()
            )
            parts.append(f"• {label}: {ln['url']}")
        parts.append("")

    return "\n".join(parts).rstrip() + "\n"


def _block_kind_label(kind: str) -> str:
    return {
        "intro": "Intro", "segment": "Segmento", "interview": "Entrevista",
        "sponsor": "Sponsor", "break": "Pausa", "outro": "Outro",
        "custom": "Bloque",
    }.get(kind or "", "Bloque")


@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/show-notes")
@require_auth
def generate_show_notes(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        ep = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404
        blocks = db.execute(
            "SELECT position, kind, title, duration_estimate, notes "
            "FROM episode_blocks WHERE episode_id=? ORDER BY position, id",
            (ep_id,),
        ).fetchall()
        guests = db.execute(
            "SELECT name, email, role, bio FROM episode_guests WHERE episode_id=? ORDER BY id",
            (ep_id,),
        ).fetchall()
        links = db.execute(
            "SELECT platform, url FROM episode_links WHERE episode_id=? ORDER BY platform",
            (ep_id,),
        ).fetchall()

        text = _build_show_notes_text(ep, blocks, guests, links)

        # Cumulative chapter offsets in structured form (frontend can render
        # them as a separate copyable block, e.g. just the YouTube chapters).
        chapters_struct = []
        offset = 0.0
        for b in blocks:
            label = (b["title"] or "").strip() or _block_kind_label(b["kind"])
            chapters_struct.append({
                "offset_seconds": int(round(offset)),
                "offset_label": _fmt_offset(offset),
                "title": label,
                "kind": b["kind"],
            })
            offset += float(b["duration_estimate"] or 0) * 60.0

        return jsonify({
            "text": text,
            "title": ep["title"] or "",
            "description": ep["description"] or "",
            "chapters": chapters_struct,
            "guests": [
                {"name": g["name"], "role": g["role"], "bio": g["bio"] or ""}
                for g in guests
            ],
            "links": [
                {"platform": ln["platform"], "url": ln["url"]} for ln in links
            ],
        })
    finally:
        db.close()


# ---------------------------------------------------------------------------
# AI notes sync + publish
# ---------------------------------------------------------------------------

@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/sync-notes")
@require_auth
def force_sync_notes(slug, ep_id):
    """Force re-sync AI notes from postPod, resetting the edited flag."""
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        db.execute("UPDATE episodes SET ai_notes_edited=0 WHERE id=?", (ep_id,))
        db.commit()
        row = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
    finally:
        db.close()

    if not row:
        return jsonify({"error": "episodio no encontrado"}), 404

    shared_project_id = None
    if row["production_meta"]:
        try:
            shared_project_id = _json.loads(row["production_meta"]).get("shared_project_id")
        except (TypeError, ValueError):
            pass

    if shared_project_id:
        _sync_ai_notes(slug, ep_id, shared_project_id)

    db = get_db(slug)
    try:
        updated = db.execute("SELECT ai_summary, ai_highlights, ai_notes_synced_at FROM episodes WHERE id=?", (ep_id,)).fetchone()
    finally:
        db.close()

    return jsonify({
        "ok": True,
        "ai_summary": updated["ai_summary"] if updated else None,
        "ai_highlights": _json.loads(updated["ai_highlights"]) if (updated and updated["ai_highlights"]) else [],
        "synced_at": updated["ai_notes_synced_at"] if updated else None,
    })


def upload_episode_media(slug: str, ep_id: int, media_path) -> dict:
    """Sube el archivo a hosting (VPS) y marca el episodio como publicado.

    Lógica compartida entre el endpoint web (ruta en el servidor) y la API
    del Mac (archivo subido por partes).
    Returns {"ok": True, "media_url": ...} o {"ok": False, "error": ...}.
    """
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
    finally:
        db.close()

    if not row:
        return {"ok": False, "error": "episodio no encontrado"}

    from pathlib import Path
    media_path = Path(media_path)
    if not media_path.is_file():
        return {"ok": False, "error": f"Archivo no encontrado: {media_path}"}

    import hosting
    ep_num = row["episode_number"] or ep_id
    filename = f"ep{ep_num:03d}-{slug}{media_path.suffix}"
    result = hosting.upload_file(slug, media_path, filename)

    if not result["ok"]:
        return result

    db = get_db(slug)
    try:
        db.execute("UPDATE episodes SET media_url=?, status='published' WHERE id=?", (result["url"], ep_id))
        db.commit()
    finally:
        db.close()

    return {"ok": True, "media_url": result["url"]}


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/publish")
@require_auth
def publish_episode(slug, ep_id):
    """Publish: upload media to VPS, update status, save media_url."""
    _ensure_podcast(slug)

    data = request.get_json(silent=True) or {}
    media_file = data.get("media_file")
    if not media_file:
        return jsonify({"error": "se requiere media_file (ruta al archivo exportado)"}), 400

    result = upload_episode_media(slug, ep_id, media_file)
    if not result["ok"]:
        if result["error"] == "episodio no encontrado":
            return jsonify({"error": result["error"]}), 404
        if result["error"].startswith("Archivo no encontrado"):
            return jsonify({"error": result["error"]}), 400
        return jsonify({"error": result["error"]}), 500

    return jsonify({"ok": True, "media_url": result["media_url"], "status": "published"})
