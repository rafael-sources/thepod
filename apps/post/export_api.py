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
    keys = row.keys()
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
        "generate_notes": bool(row["generate_notes"]) if "generate_notes" in keys else False,
        "notes_file": row["notes_file"] if "notes_file" in keys else None,
        "enhance_speech": bool(row["enhance_speech"]) if "enhance_speech" in keys else False,
        "range_start": row["range_start"] if "range_start" in keys else None,
        "range_end":   row["range_end"]   if "range_end"   in keys else None,
        "spotlight": bool(row["spotlight"]) if "spotlight" in keys else False,
        "use_background": bool(row["use_background"]) if "use_background" in keys else False,
        "moment_banner": bool(row["moment_banner"]) if "moment_banner" in keys else False,
        "banner_position": row["banner_position"] if "banner_position" in keys else "bottom",
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

    burn = data.get("burn_captions") or None
    burn_json = None
    if burn:
        import json as _json
        try:
            mfid = int(burn.get("media_file_id"))
            lang = (burn.get("language") or "").strip().lower()
            if mfid and lang:
                burn_json = _json.dumps({"media_file_id": mfid, "language": lang})
        except (TypeError, ValueError):
            pass

    generate_notes = 1 if data.get("generate_notes") else 0
    enhance_speech = 1 if data.get("enhance_speech") else 0
    spotlight = 1 if data.get("spotlight") else 0
    use_background = 1 if data.get("use_background") else 0
    moment_banner = 1 if data.get("moment_banner") else 0
    banner_position = (data.get("banner_position") or "bottom").strip().lower()
    if banner_position not in ("top", "middle", "bottom"):
        banner_position = "bottom"

    # Optional partial-range export: render only the segment [range_start,
    # range_end] of the final timeline. Internal cuts/transcript_cuts/zooms
    # within the range are preserved — only material outside the range is
    # discarded.
    def _range_seconds(key):
        v = data.get(key)
        if v is None or v == "":
            return None
        try:
            f = float(v)
        except (TypeError, ValueError):
            return None
        return f if f >= 0 else None

    range_start = _range_seconds("range_start")
    range_end   = _range_seconds("range_end")
    if range_start is not None and range_end is not None and range_end <= range_start:
        return jsonify({"error": "range_end debe ser mayor que range_start"}), 400

    db = get_db(slug)
    try:
        # Quick sanity — reject if timeline is empty
        row = db.execute(
            "SELECT COUNT(*) AS n FROM timeline_clips"
        ).fetchone()
        if (row["n"] or 0) == 0:
            return jsonify({"error": "el timeline está vacío — añade al menos un clip"}), 400

        cur = db.execute(
            "INSERT INTO export_jobs (preset_id, status, burn_captions_json, "
            "generate_notes, enhance_speech, range_start, range_end, spotlight, use_background, moment_banner, banner_position) "
            "VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (preset_id, burn_json, generate_notes, enhance_speech, range_start, range_end, spotlight, use_background, moment_banner, banner_position),
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


@bp.delete("/api/projects/<slug>/export/<int:job_id>")
@require_auth
def delete_export(slug, job_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT * FROM export_jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row:
            return jsonify({"error": "job no encontrado"}), 404
        if row["status"] in ("pending", "running"):
            return jsonify({"error": "no se puede borrar un job en curso"}), 409
        exports_dir = PROJECTS_DIR / slug / "exports"
        for fname in (row["output_file"], row["notes_file"]):
            if fname:
                fp = exports_dir / fname
                if fp.is_file():
                    fp.unlink()
        log_name = f"{job_id}_{row['preset_id']}.log"
        log_path = exports_dir / log_name
        if log_path.is_file():
            log_path.unlink()
        db.execute("DELETE FROM export_jobs WHERE id=?", (job_id,))
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


@bp.get("/api/projects/<slug>/export/<int:job_id>/notes")
@require_auth
def download_export_notes(slug, job_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT notes_file, status FROM export_jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row or not row["notes_file"]:
            return jsonify({"error": "notas no disponibles"}), 404
        notes_path = PROJECTS_DIR / slug / "exports" / row["notes_file"]
        if not notes_path.is_file():
            return jsonify({"error": "archivo de notas no encontrado"}), 410
        as_attach = request.args.get("attachment", "1") != "0"
        return send_file(
            str(notes_path),
            mimetype="text/plain; charset=utf-8",
            as_attachment=as_attach,
            download_name=row["notes_file"],
        )
    finally:
        db.close()
