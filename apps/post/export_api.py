"""
REST endpoints for exports.
"""

from flask import Blueprint, abort, jsonify, request, send_file

from auth import require_auth
from config import EXPORT_PRESETS, PROJECTS_DIR, find_preset
from db import get_db
from exporter import cancel_export, start_export_thread


bp = Blueprint("export_api", __name__)


def _ensure_project(slug):
    if not (PROJECTS_DIR / slug).exists():
        abort(404, description="proyecto no encontrado")


def _serialize_job(row):
    return {
        "id": row["id"],
        "preset_id": row["preset_id"],
        "status": row["status"],
        "progress": row["progress"] or 0,
        "output_file": row["output_file"],
        "error_msg": row["error_msg"],
        "started_at": row["started_at"],
        "finished_at": row["finished_at"],
        "created_at": row["created_at"],
    }


@bp.get("/api/export/presets")
@require_auth
def list_presets():
    # Group by platform for the UI
    return jsonify(EXPORT_PRESETS)


@bp.post("/api/projects/<slug>/export")
@require_auth
def create_export(slug):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    preset_id = data.get("preset_id")
    if not preset_id or not find_preset(preset_id):
        return jsonify({"error": "preset_id inválido"}), 400

    db = get_db(slug)
    try:
        # Quick sanity — reject if timeline is empty
        row = db.execute(
            "SELECT COUNT(*) AS n FROM timeline_clips"
        ).fetchone()
        if (row["n"] or 0) == 0:
            return jsonify({"error": "el timeline está vacío — añade al menos un clip"}), 400

        cur = db.execute(
            "INSERT INTO export_jobs (preset_id, status) VALUES (?, 'pending')",
            (preset_id,),
        )
        db.commit()
        job_id = cur.lastrowid
    finally:
        db.close()

    start_export_thread(slug, job_id)
    return jsonify({"job_id": job_id, "status": "pending"}), 202


@bp.get("/api/projects/<slug>/export/<int:job_id>")
@require_auth
def get_export(slug, job_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT * FROM export_jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row:
            return jsonify({"error": "job no encontrado"}), 404
        return jsonify(_serialize_job(row))
    finally:
        db.close()


@bp.get("/api/projects/<slug>/exports")
@require_auth
def list_exports(slug):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM export_jobs ORDER BY created_at DESC"
        ).fetchall()
        return jsonify([_serialize_job(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/projects/<slug>/export/<int:job_id>/cancel")
@require_auth
def cancel_export_job(slug, job_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT status FROM export_jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row:
            return jsonify({"error": "job no encontrado"}), 404
        if row["status"] not in ("pending", "running"):
            return jsonify({"error": f"no se puede cancelar un job en estado '{row['status']}'"}), 409
    finally:
        db.close()
    ok = cancel_export(slug, job_id)
    if not ok:
        # Might be still pending (not yet started) — mark as cancelled directly
        db = get_db(slug)
        try:
            db.execute(
                "UPDATE export_jobs SET status='cancelled', error_msg='cancelado antes de iniciar', finished_at=datetime('now') WHERE id=? AND status='pending'",
                (job_id,),
            )
            db.commit()
        finally:
            db.close()
    return jsonify({"ok": True})


@bp.get("/api/projects/<slug>/export/<int:job_id>/download")
@require_auth
def download_export(slug, job_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT output_file, status FROM export_jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row or row["status"] != "done" or not row["output_file"]:
            return jsonify({"error": "job no está disponible"}), 409
        out_path = PROJECTS_DIR / slug / "exports" / row["output_file"]
        if not out_path.is_file():
            return jsonify({"error": "archivo no encontrado"}), 410
        as_attach = request.args.get("attachment", "1") != "0"
        return send_file(
            str(out_path),
            as_attachment=as_attach,
            download_name=row["output_file"],
        )
    finally:
        db.close()
