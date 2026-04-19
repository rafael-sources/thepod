"""
Episodes, ideas (with voting), and script sections.
All endpoints scoped under `/api/podcasts/<slug>/`.
"""

from flask import Blueprint, abort, jsonify, request, session

from auth import require_auth
from config import PODCASTS_DIR
from db import get_db


bp = Blueprint("episodes", __name__)

EPISODE_STATUSES = ("idea", "planning", "scripted", "recorded", "published")
IDEA_STATUSES = ("proposed", "accepted", "rejected")


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _serialize_episode(row):
    return {
        "id": row["id"],
        "episode_number": row["episode_number"],
        "title": row["title"],
        "description": row["description"] or "",
        "status": row["status"],
        "scheduled_date": row["scheduled_date"],
        "duration_estimate": row["duration_estimate"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
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
    }


def _current_user():
    return session.get("username") or "anon"


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
        max_row = db.execute("SELECT COALESCE(MAX(episode_number), 0) AS n FROM episodes").fetchone()
        next_number = (max_row["n"] or 0) + 1
        status = data.get("status") or "idea"
        if status not in EPISODE_STATUSES:
            return jsonify({"error": f"status inválido: {status}"}), 400

        cur = db.execute(
            "INSERT INTO episodes (episode_number, title, description, status, scheduled_date, duration_estimate) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                next_number,
                title,
                data.get("description") or "",
                status,
                data.get("scheduled_date"),
                data.get("duration_estimate"),
            ),
        )
        db.commit()
        row = db.execute("SELECT * FROM episodes WHERE id=?", (cur.lastrowid,)).fetchone()
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
        return jsonify(_serialize_episode(row))
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/episodes/<int:ep_id>")
@require_auth
def update_episode(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    allowed = {"title", "description", "scheduled_date", "duration_estimate", "status", "episode_number"}
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
        db.execute("DELETE FROM episodes WHERE id=?", (ep_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


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
        for k in ("speaker", "content", "estimated_duration", "notes"):
            if k in data:
                other_updates[k] = data[k]
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
