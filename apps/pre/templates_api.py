"""
Show templates: define a recurring podcast format once
(rundown blocks + base script sections), and reuse it on every new
episode. Each podcast can have multiple templates; one is marked default.

All endpoints scoped under `/api/podcasts/<slug>/`.
"""

from flask import Blueprint, abort, jsonify, request

from auth import require_auth
from config import PODCASTS_DIR
from db import get_db


bp = Blueprint("templates", __name__)


BLOCK_KINDS = ("intro", "segment", "interview", "sponsor", "break", "outro", "custom")


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _serialize_template(row, counts=None):
    out = {
        "id": row["id"],
        "name": row["name"],
        "description": row["description"] or "",
        "is_default": bool(row["is_default"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }
    if counts is not None:
        out["block_count"] = counts.get("blocks", 0)
        out["section_count"] = counts.get("sections", 0)
    return out


def _serialize_block(row):
    return {
        "id": row["id"],
        "template_id": row["template_id"],
        "position": row["position"],
        "kind": row["kind"],
        "title": row["title"] or "",
        "duration_estimate": row["duration_estimate"],
        "notes": row["notes"] or "",
        "created_at": row["created_at"],
    }


def _serialize_section(row):
    return {
        "id": row["id"],
        "template_id": row["template_id"],
        "position": row["position"],
        "speaker": row["speaker"] or "",
        "content": row["content"] or "",
        "estimated_duration": row["estimated_duration"],
        "notes": row["notes"] or "",
        "created_at": row["created_at"],
    }


def _normalize_block_positions(db, template_id):
    rows = db.execute(
        "SELECT id FROM template_blocks WHERE template_id=? ORDER BY position, id",
        (template_id,),
    ).fetchall()
    for i, r in enumerate(rows):
        db.execute("UPDATE template_blocks SET position=? WHERE id=?", (i, r["id"]))


def _normalize_section_positions(db, template_id):
    rows = db.execute(
        "SELECT id FROM template_sections WHERE template_id=? ORDER BY position, id",
        (template_id,),
    ).fetchall()
    for i, r in enumerate(rows):
        db.execute("UPDATE template_sections SET position=? WHERE id=?", (i, r["id"]))


def _clear_default(db):
    db.execute("UPDATE templates SET is_default=0 WHERE is_default=1")


# ---------------------------------------------------------------------------
# Template CRUD
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/templates")
@require_auth
def list_templates(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM templates ORDER BY is_default DESC, name COLLATE NOCASE"
        ).fetchall()
        # Counts in one query each (cheap; usually <10 templates per podcast)
        out = []
        for r in rows:
            blocks = db.execute(
                "SELECT COUNT(*) AS n FROM template_blocks WHERE template_id=?",
                (r["id"],),
            ).fetchone()["n"]
            sections = db.execute(
                "SELECT COUNT(*) AS n FROM template_sections WHERE template_id=?",
                (r["id"],),
            ).fetchone()["n"]
            out.append(_serialize_template(r, {"blocks": blocks, "sections": sections}))
        return jsonify(out)
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/templates")
@require_auth
def create_template(slug):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name requerido"}), 400
    description = (data.get("description") or "").strip() or None
    make_default = bool(data.get("is_default"))

    db = get_db(slug)
    try:
        # If this is the first template, force default=1 regardless of input.
        n_existing = db.execute("SELECT COUNT(*) AS n FROM templates").fetchone()["n"]
        if n_existing == 0:
            make_default = True
        if make_default:
            _clear_default(db)
        cur = db.execute(
            "INSERT INTO templates (name, description, is_default) VALUES (?, ?, ?)",
            (name, description, 1 if make_default else 0),
        )
        db.commit()
        row = db.execute("SELECT * FROM templates WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_template(row, {"blocks": 0, "sections": 0})), 201
    finally:
        db.close()


@bp.get("/api/podcasts/<slug>/templates/<int:tid>")
@require_auth
def get_template(slug, tid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM templates WHERE id=?", (tid,)).fetchone()
        if not row:
            return jsonify({"error": "plantilla no encontrada"}), 404
        blocks = db.execute(
            "SELECT * FROM template_blocks WHERE template_id=? ORDER BY position, id",
            (tid,),
        ).fetchall()
        sections = db.execute(
            "SELECT * FROM template_sections WHERE template_id=? ORDER BY position, id",
            (tid,),
        ).fetchall()
        return jsonify({
            **_serialize_template(row),
            "blocks": [_serialize_block(b) for b in blocks],
            "sections": [_serialize_section(s) for s in sections],
        })
    finally:
        db.close()


@bp.patch("/api/podcasts/<slug>/templates/<int:tid>")
@require_auth
def update_template(slug, tid):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        existing = db.execute("SELECT * FROM templates WHERE id=?", (tid,)).fetchone()
        if not existing:
            return jsonify({"error": "plantilla no encontrada"}), 404

        updates, params = [], []
        if "name" in data:
            n = (data["name"] or "").strip()
            if not n:
                return jsonify({"error": "name no puede estar vacío"}), 400
            updates.append("name=?"); params.append(n)
        if "description" in data:
            updates.append("description=?"); params.append((data["description"] or "").strip() or None)
        if "is_default" in data:
            v = bool(data["is_default"])
            if v:
                _clear_default(db)
                updates.append("is_default=?"); params.append(1)
            else:
                # Disallow un-defaulting the only template; otherwise nobody is default.
                if existing["is_default"]:
                    n_total = db.execute("SELECT COUNT(*) AS n FROM templates").fetchone()["n"]
                    if n_total <= 1:
                        return jsonify({"error": "al menos una plantilla debe ser default"}), 400
                updates.append("is_default=?"); params.append(0)
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(tid)
        db.execute(
            f"UPDATE templates SET {', '.join(updates)}, updated_at=datetime('now') WHERE id=?",
            params,
        )
        db.commit()
        row = db.execute("SELECT * FROM templates WHERE id=?", (tid,)).fetchone()
        return jsonify(_serialize_template(row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/templates/<int:tid>")
@require_auth
def delete_template(slug, tid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM templates WHERE id=?", (tid,)).fetchone()
        if not row:
            return jsonify({"error": "plantilla no encontrada"}), 404
        was_default = bool(row["is_default"])
        db.execute("DELETE FROM templates WHERE id=?", (tid,))
        # If we just deleted the default and others remain, promote the
        # oldest remaining one to default so the field stays a valid pointer.
        if was_default:
            other = db.execute("SELECT id FROM templates ORDER BY created_at, id LIMIT 1").fetchone()
            if other:
                db.execute("UPDATE templates SET is_default=1 WHERE id=?", (other["id"],))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Template blocks
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/templates/<int:tid>/blocks")
@require_auth
def list_template_blocks(slug, tid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM template_blocks WHERE template_id=? ORDER BY position, id",
            (tid,),
        ).fetchall()
        return jsonify([_serialize_block(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/templates/<int:tid>/blocks")
@require_auth
def create_template_block(slug, tid):
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
        if not db.execute("SELECT id FROM templates WHERE id=?", (tid,)).fetchone():
            return jsonify({"error": "plantilla no encontrada"}), 404
        max_pos = db.execute(
            "SELECT COALESCE(MAX(position), -1) AS m FROM template_blocks WHERE template_id=?",
            (tid,),
        ).fetchone()["m"]
        cur = db.execute(
            "INSERT INTO template_blocks (template_id, position, kind, title, duration_estimate, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (tid, max_pos + 1, kind, title, duration, notes),
        )
        db.commit()
        row = db.execute("SELECT * FROM template_blocks WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_block(row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/template-blocks/<int:block_id>")
@require_auth
def update_template_block(slug, block_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM template_blocks WHERE id=?", (block_id,)).fetchone()
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
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(block_id)
        db.execute(f"UPDATE template_blocks SET {', '.join(updates)} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM template_blocks WHERE id=?", (block_id,)).fetchone()
        return jsonify(_serialize_block(row))
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/templates/<int:tid>/blocks/reorder")
@require_auth
def reorder_template_blocks(slug, tid):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    order = data.get("order") or []
    if not isinstance(order, list):
        return jsonify({"error": "order debe ser lista de IDs"}), 400
    db = get_db(slug)
    try:
        for i, bid in enumerate(order):
            db.execute(
                "UPDATE template_blocks SET position=? WHERE id=? AND template_id=?",
                (i, int(bid), tid),
            )
        _normalize_block_positions(db, tid)
        db.commit()
        rows = db.execute(
            "SELECT * FROM template_blocks WHERE template_id=? ORDER BY position, id",
            (tid,),
        ).fetchall()
        return jsonify([_serialize_block(r) for r in rows])
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/template-blocks/<int:block_id>")
@require_auth
def delete_template_block(slug, block_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT template_id FROM template_blocks WHERE id=?", (block_id,)).fetchone()
        if not row:
            return jsonify({"error": "bloque no encontrado"}), 404
        tid = row["template_id"]
        db.execute("DELETE FROM template_blocks WHERE id=?", (block_id,))
        _normalize_block_positions(db, tid)
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Template script sections
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/templates/<int:tid>/sections")
@require_auth
def list_template_sections(slug, tid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM template_sections WHERE template_id=? ORDER BY position, id",
            (tid,),
        ).fetchall()
        return jsonify([_serialize_section(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/templates/<int:tid>/sections")
@require_auth
def create_template_section(slug, tid):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        if not db.execute("SELECT id FROM templates WHERE id=?", (tid,)).fetchone():
            return jsonify({"error": "plantilla no encontrada"}), 404
        n = db.execute(
            "SELECT COUNT(*) AS n FROM template_sections WHERE template_id=?", (tid,)
        ).fetchone()["n"]
        cur = db.execute(
            "INSERT INTO template_sections (template_id, position, speaker, content, estimated_duration, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                tid, n,
                (data.get("speaker") or "").strip(),
                data.get("content") or "",
                data.get("estimated_duration"),
                data.get("notes") or "",
            ),
        )
        db.commit()
        row = db.execute("SELECT * FROM template_sections WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_section(row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/template-sections/<int:sec_id>")
@require_auth
def update_template_section(slug, sec_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        existing = db.execute("SELECT * FROM template_sections WHERE id=?", (sec_id,)).fetchone()
        if not existing:
            return jsonify({"error": "sección no encontrada"}), 404
        tid = existing["template_id"]

        if "position" in data and data["position"] is not None:
            new_pos = max(0, int(data["position"]))
            old_pos = existing["position"]
            if new_pos != old_pos:
                n = db.execute(
                    "SELECT COUNT(*) AS n FROM template_sections WHERE template_id=?", (tid,)
                ).fetchone()["n"]
                new_pos = min(new_pos, n - 1)
                db.execute("UPDATE template_sections SET position=-1 WHERE id=?", (sec_id,))
                if new_pos > old_pos:
                    db.execute(
                        "UPDATE template_sections SET position=position-1 "
                        "WHERE template_id=? AND position > ? AND position <= ?",
                        (tid, old_pos, new_pos),
                    )
                else:
                    db.execute(
                        "UPDATE template_sections SET position=position+1 "
                        "WHERE template_id=? AND position >= ? AND position < ?",
                        (tid, new_pos, old_pos),
                    )
                db.execute("UPDATE template_sections SET position=? WHERE id=?", (new_pos, sec_id))
                _normalize_section_positions(db, tid)

        other_updates = {}
        for k in ("speaker", "content", "estimated_duration", "notes"):
            if k in data:
                other_updates[k] = data[k]
        if other_updates:
            cols = ", ".join(f"{k}=?" for k in other_updates)
            params = list(other_updates.values()) + [sec_id]
            db.execute(f"UPDATE template_sections SET {cols} WHERE id=?", params)

        db.commit()
        row = db.execute("SELECT * FROM template_sections WHERE id=?", (sec_id,)).fetchone()
        return jsonify(_serialize_section(row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/template-sections/<int:sec_id>")
@require_auth
def delete_template_section(slug, sec_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT template_id FROM template_sections WHERE id=?", (sec_id,)).fetchone()
        if not row:
            return jsonify({"error": "sección no encontrada"}), 404
        tid = row["template_id"]
        db.execute("DELETE FROM template_sections WHERE id=?", (sec_id,))
        _normalize_section_positions(db, tid)
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Helper for episode creation: copy template content into a new episode.
# Imported by episodes.py — keeps the copy logic in one place.
# ---------------------------------------------------------------------------

def copy_template_into_episode(db, template_id: int, episode_id: int) -> None:
    blocks = db.execute(
        "SELECT position, kind, title, duration_estimate, notes "
        "FROM template_blocks WHERE template_id=? ORDER BY position, id",
        (template_id,),
    ).fetchall()
    for b in blocks:
        db.execute(
            "INSERT INTO episode_blocks (episode_id, position, kind, title, duration_estimate, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (episode_id, b["position"], b["kind"], b["title"], b["duration_estimate"], b["notes"]),
        )
    sections = db.execute(
        "SELECT position, speaker, content, estimated_duration, notes "
        "FROM template_sections WHERE template_id=? ORDER BY position, id",
        (template_id,),
    ).fetchall()
    for s in sections:
        db.execute(
            "INSERT INTO script_sections (episode_id, position, speaker, content, estimated_duration, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (episode_id, s["position"], s["speaker"], s["content"], s["estimated_duration"], s["notes"]),
        )
