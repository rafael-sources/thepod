"""
Auto-generated captions (subtitles) using OpenAI Whisper (CPU). Each job
runs ffmpeg to extract a mono 16kHz wav from the source media, then
spawns `whisper` with the chosen language and writes an SRT sidecar next
to the media file (`<filename>.<lang>.srt`).

Whisper CPU is slow (~0.5-1x realtime) so jobs run in a background thread
and the frontend polls a job row for status.
"""

import os
import shutil
import subprocess
import threading
from pathlib import Path

from flask import Blueprint, jsonify, request

from auth import require_auth
from config import PROJECTS_DIR
from db import get_db


bp = Blueprint("captions", __name__)


# Curated set of languages — whisper accepts more, but these cover 99% of
# what a Spanish-language podcast suite will ever need + neutral fallback.
SUPPORTED_LANGUAGES = [
    {"code": "es",   "label": "Español"},
    {"code": "en",   "label": "Inglés"},
    {"code": "pt",   "label": "Portugués"},
    {"code": "fr",   "label": "Francés"},
    {"code": "de",   "label": "Alemán"},
    {"code": "it",   "label": "Italiano"},
    {"code": "ca",   "label": "Catalán"},
    {"code": "auto", "label": "Auto-detectar"},
]

DEFAULT_MODEL = "small"  # turbo is the new default but small is more portable


def _ensure_caption_jobs_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS caption_jobs (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            media_file_id   INTEGER NOT NULL,
            language        TEXT,
            model           TEXT,
            status          TEXT NOT NULL DEFAULT 'pending',
            srt_filename    TEXT,
            error_msg       TEXT,
            progress        INTEGER NOT NULL DEFAULT 0,
            created_at      TEXT DEFAULT (datetime('now')),
            finished_at     TEXT
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_caption_jobs_media ON caption_jobs(media_file_id)")
    conn.commit()


def _serialize_job(row):
    return {
        "id": row["id"],
        "media_file_id": row["media_file_id"],
        "language": row["language"],
        "model": row["model"],
        "status": row["status"],
        "srt_filename": row["srt_filename"],
        "error_msg": row["error_msg"],
        "progress": row["progress"],
        "created_at": row["created_at"],
        "finished_at": row["finished_at"],
    }


def _media_file_row(slug, file_id):
    db = get_db(slug)
    try:
        return db.execute(
            "SELECT id, filename, file_type FROM media_files WHERE id=?", (file_id,),
        ).fetchone()
    finally:
        db.close()


def _media_path(slug, mf_row):
    return PROJECTS_DIR / slug / "media" / mf_row["file_type"] / mf_row["filename"]


def _srt_filename_for(mf_row, language):
    base = mf_row["filename"]
    lang = (language or "auto").lower()
    return f"{base}.{lang}.srt"


def _update_job(slug, job_id, **fields):
    fields.pop("finished_at_marker", None)
    if not fields:
        return
    db = get_db(slug)
    try:
        cols = ", ".join(f"{k}=?" for k in fields)
        db.execute(f"UPDATE caption_jobs SET {cols} WHERE id=?",
                   (*fields.values(), job_id))
        db.commit()
    finally:
        db.close()


def _run_caption_job(slug, job_id, file_id, language, model):
    db = get_db(slug)
    try:
        mf = db.execute(
            "SELECT id, filename, file_type FROM media_files WHERE id=?", (file_id,),
        ).fetchone()
    finally:
        db.close()
    if not mf:
        _update_job(slug, job_id, status="error", error_msg="archivo no encontrado",
                    finished_at_marker=None)
        return

    media_path = _media_path(slug, mf)
    if not media_path.is_file():
        _update_job(slug, job_id, status="error", error_msg="archivo desaparecido")
        return

    _update_job(slug, job_id, status="running", progress=5)

    work_dir = media_path.parent
    wav_path = work_dir / f".{job_id}_audio.wav"
    srt_filename = _srt_filename_for(mf, language)
    final_srt = work_dir / srt_filename

    try:
        # Extract 16kHz mono wav so Whisper avoids extra resampling on CPU.
        proc = subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-i", str(media_path),
             "-vn", "-ac", "1", "-ar", "16000",
             str(wav_path)],
            capture_output=True, text=True, timeout=600,
        )
        if proc.returncode != 0:
            _update_job(slug, job_id, status="error",
                        error_msg=f"ffmpeg extract: {proc.stderr[:200]}",
                        finished_at_marker=None)
            return
        _update_job(slug, job_id, progress=20)

        cmd = [
            "whisper", str(wav_path),
            "--model", model or DEFAULT_MODEL,
            "--output_format", "srt",
            "--output_dir", str(work_dir),
            "--device", "cpu",
            "--fp16", "False",
        ]
        if language and language != "auto":
            cmd += ["--language", language]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        if proc.returncode != 0:
            _update_job(slug, job_id, status="error",
                        error_msg=f"whisper: {proc.stderr[:300]}")
            return

        # whisper writes <wavstem>.srt — rename to our convention
        whisper_out = work_dir / (wav_path.stem + ".srt")
        if not whisper_out.is_file():
            _update_job(slug, job_id, status="error",
                        error_msg="whisper no produjo SRT")
            return
        if final_srt.exists():
            final_srt.unlink()
        whisper_out.rename(final_srt)

        _update_job(slug, job_id, status="done", progress=100,
                    srt_filename=srt_filename,
                    finished_at_marker=None)
        # After done, fix the finished_at via SQL since UPDATE with =? doesn't
        # accept SQL functions.
        db = get_db(slug)
        try:
            db.execute("UPDATE caption_jobs SET finished_at=datetime('now') WHERE id=?", (job_id,))
            db.commit()
        finally:
            db.close()
    except subprocess.TimeoutExpired:
        _update_job(slug, job_id, status="error", error_msg="timeout")
    except Exception as e:
        _update_job(slug, job_id, status="error", error_msg=str(e)[:200])
    finally:
        try:
            if wav_path.exists(): wav_path.unlink()
            for stale in work_dir.glob(f".{job_id}_audio.*"):
                try: stale.unlink()
                except OSError: pass
        except OSError:
            pass


@bp.get("/api/captions/languages")
@require_auth
def list_languages():
    return jsonify(SUPPORTED_LANGUAGES)


@bp.post("/api/projects/<slug>/files/<int:file_id>/captions")
@require_auth
def start_caption_job(slug, file_id):
    data = request.get_json(silent=True) or {}
    language = (data.get("language") or "auto").strip().lower()
    model = (data.get("model") or DEFAULT_MODEL).strip()

    mf = _media_file_row(slug, file_id)
    if not mf:
        return jsonify({"error": "archivo no encontrado"}), 404
    if mf["file_type"] not in ("video", "audio"):
        return jsonify({"error": "sólo se soportan archivos de video o audio"}), 400

    db = get_db(slug)
    try:
        _ensure_caption_jobs_table(db)
        # If a running job already exists for this (file, language), return it.
        existing = db.execute(
            "SELECT * FROM caption_jobs WHERE media_file_id=? AND language=? "
            "AND status IN ('pending','running') ORDER BY id DESC LIMIT 1",
            (file_id, language),
        ).fetchone()
        if existing:
            return jsonify(_serialize_job(existing)), 200

        cur = db.execute(
            "INSERT INTO caption_jobs (media_file_id, language, model, status) "
            "VALUES (?, ?, ?, 'pending')",
            (file_id, language, model),
        )
        db.commit()
        job_id = cur.lastrowid
    finally:
        db.close()

    if not shutil.which("whisper"):
        _update_job(slug, job_id, status="error",
                    error_msg="whisper no está instalado en el server")
    else:
        t = threading.Thread(
            target=_run_caption_job, args=(slug, job_id, file_id, language, model),
            daemon=True, name=f"captions-{job_id}",
        )
        t.start()

    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM caption_jobs WHERE id=?", (job_id,)).fetchone()
    finally:
        db.close()
    return jsonify(_serialize_job(row)), 201


@bp.get("/api/projects/<slug>/caption-jobs/<int:job_id>")
@require_auth
def get_caption_job(slug, job_id):
    db = get_db(slug)
    try:
        _ensure_caption_jobs_table(db)
        row = db.execute("SELECT * FROM caption_jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            return jsonify({"error": "job no encontrado"}), 404
        return jsonify(_serialize_job(row))
    finally:
        db.close()


@bp.get("/api/projects/<slug>/files/<int:file_id>/captions")
@require_auth
def list_captions_for_file(slug, file_id):
    """Return existing SRT sidecars + recent jobs for this file."""
    mf = _media_file_row(slug, file_id)
    if not mf:
        return jsonify({"error": "archivo no encontrado"}), 404

    media_dir = _media_path(slug, mf).parent
    base_name = mf["filename"]
    captions = []
    for entry in sorted(media_dir.iterdir()):
        if entry.is_file() and entry.name.startswith(base_name + ".") and entry.name.endswith(".srt"):
            # name pattern: <basename>.<lang>.srt
            inner = entry.name[len(base_name) + 1:-4]  # strip prefix + ".srt"
            captions.append({
                "language": inner,
                "filename": entry.name,
                "url": f"/media/projects/{slug}/{mf['file_type']}/{entry.name}",
                "size_bytes": entry.stat().st_size,
            })

    db = get_db(slug)
    try:
        _ensure_caption_jobs_table(db)
        jobs = db.execute(
            "SELECT * FROM caption_jobs WHERE media_file_id=? ORDER BY id DESC LIMIT 5",
            (file_id,),
        ).fetchall()
    finally:
        db.close()
    return jsonify({
        "captions": captions,
        "jobs": [_serialize_job(j) for j in jobs],
    })


@bp.delete("/api/projects/<slug>/files/<int:file_id>/captions/<lang>")
@require_auth
def delete_caption(slug, file_id, lang):
    mf = _media_file_row(slug, file_id)
    if not mf:
        return jsonify({"error": "archivo no encontrado"}), 404
    media_dir = _media_path(slug, mf).parent
    target = media_dir / _srt_filename_for(mf, lang)
    if target.is_file():
        target.unlink()
    return jsonify({"ok": True})
