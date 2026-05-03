"""
Transcript-editor cuts.

The transcript editor lets the user delete words by selecting tokens; each
deletion records a time range in `transcript_cuts`, which the exporter
subtracts from the final keep-ranges. Non-destructive: cuts can be removed
to restore the original audio/video.

Distinct from `operations` (which require a moment + a clip context); these
are flat time ranges and stand on their own.
"""

from flask import Blueprint, abort, jsonify, request

from auth import require_auth
from config import PROJECTS_DIR
from db import get_db


bp = Blueprint("transcript_api", __name__)


def _ensure_project(slug):
    if not (PROJECTS_DIR / slug).exists():
        abort(404, description="proyecto no encontrado")


def _serialize_cut(row):
    return {
        "id": row["id"],
        "start_seconds": float(row["start_seconds"]),
        "end_seconds": float(row["end_seconds"]),
        "label": row["label"] or "",
        "created_at": row["created_at"],
    }


@bp.get("/api/projects/<slug>/transcript-cuts")
@require_auth
def list_cuts(slug):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM transcript_cuts ORDER BY start_seconds, id"
        ).fetchall()
        return jsonify([_serialize_cut(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/projects/<slug>/transcript-cuts")
@require_auth
def create_cut(slug):
    """Body shape:
        {start_seconds: float, end_seconds: float, label?: str}
      OR
        {cuts: [{start_seconds, end_seconds, label?}, ...]}
    The batch form is used by the "delete all filler words" action so a
    single API call covers dozens of deletions.
    """
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    items = data.get("cuts")
    if items is None:
        items = [data]
    if not isinstance(items, list) or not items:
        return jsonify({"error": "se requiere start_seconds y end_seconds"}), 400

    parsed = []
    for raw in items:
        try:
            s = float(raw.get("start_seconds"))
            e = float(raw.get("end_seconds"))
        except (TypeError, ValueError):
            return jsonify({"error": "start/end inválidos"}), 400
        if e <= s:
            return jsonify({"error": "end debe ser > start"}), 400
        parsed.append((s, e, (raw.get("label") or "").strip() or None))

    db = get_db(slug)
    try:
        created_ids = []
        for s, e, lbl in parsed:
            cur = db.execute(
                "INSERT INTO transcript_cuts (start_seconds, end_seconds, label) VALUES (?, ?, ?)",
                (s, e, lbl),
            )
            created_ids.append(cur.lastrowid)
        db.commit()
        rows = db.execute(
            "SELECT * FROM transcript_cuts WHERE id IN (" + ",".join(["?"] * len(created_ids)) + ")",
            created_ids,
        ).fetchall()
        out = [_serialize_cut(r) for r in rows]
    finally:
        db.close()
    return jsonify(out if len(out) > 1 else out[0]), 201


@bp.delete("/api/projects/<slug>/transcript-cuts/<int:cut_id>")
@require_auth
def delete_cut(slug, cut_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        if not db.execute("SELECT id FROM transcript_cuts WHERE id=?", (cut_id,)).fetchone():
            return jsonify({"error": "cut no encontrado"}), 404
        db.execute("DELETE FROM transcript_cuts WHERE id=?", (cut_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.delete("/api/projects/<slug>/transcript-cuts")
@require_auth
def delete_all_cuts(slug):
    """Wipe every cut — the transcript editor's "Restore everything" action."""
    _ensure_project(slug)
    db = get_db(slug)
    try:
        db.execute("DELETE FROM transcript_cuts")
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()
