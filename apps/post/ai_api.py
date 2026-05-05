"""
AI Analysis API for postPod.

Provides endpoints to trigger AI analysis of episode transcripts (full, notes-only,
clips-only). Analysis runs in a background thread; the frontend polls for results.

Endpoints:
    POST /api/projects/<slug>/ai/analyze           — full analysis (notes + clips)
    POST /api/projects/<slug>/ai/regenerate-notes  — notes only
    POST /api/projects/<slug>/ai/regenerate-clips  — clips only
    GET  /api/projects/<slug>/ai/results           — latest notes + clips + active job
    GET  /api/projects/<slug>/ai/show-notes        — public endpoint (server-to-server)
"""

from __future__ import annotations

import json
import threading
from pathlib import Path

from flask import Blueprint, jsonify, request

from auth import require_auth
from config import INTEGRATION_SECRET, PROJECTS_DIR
from db import get_db
import ai_engine

# Call once at module load to ensure default AI config is present.
ai_engine.ensure_ai_config()

bp = Blueprint("ai_api", __name__)


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def _ensure_ai_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ai_analysis (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            type        TEXT NOT NULL CHECK(type IN ('full', 'notes', 'clips')),
            status      TEXT NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending','running','done','error')),
            summary     TEXT,
            highlights  TEXT,
            clips       TEXT,
            model       TEXT,
            error_msg   TEXT,
            created_at  TEXT DEFAULT (datetime('now'))
        )
    """)
    conn.commit()


def _serialize_analysis(row) -> dict:
    """Convert a DB row to a dict, JSON-parsing highlights and clips fields."""
    highlights = row["highlights"]
    if highlights:
        try:
            highlights = json.loads(highlights)
        except (json.JSONDecodeError, TypeError):
            pass

    clips = row["clips"]
    if clips:
        try:
            clips = json.loads(clips)
        except (json.JSONDecodeError, TypeError):
            pass

    return {
        "id": row["id"],
        "type": row["type"],
        "status": row["status"],
        "summary": row["summary"],
        "highlights": highlights,
        "clips": clips,
        "model": row["model"],
        "error_msg": row["error_msg"],
        "created_at": row["created_at"],
    }


# ---------------------------------------------------------------------------
# Transcript collection
# ---------------------------------------------------------------------------

def _collect_transcript_text(slug: str) -> str | None:
    """Gather all *.words.json files from the project's media directory.

    Each file contains either:
      - A list: [{"w": "word", "s": start, "e": end}, ...]
      - A dict: {"language": "es", "duration": 123.4, "words": [...]}

    Returns all words joined with spaces, files joined with double newlines.
    Returns None if no word files found or no words extracted.
    """
    media_dir = PROJECTS_DIR / slug / "media"
    if not media_dir.is_dir():
        return None

    file_texts: list[str] = []

    # Search both video and audio subdirectories
    for subdir in ("video", "audio"):
        sub = media_dir / subdir
        if not sub.is_dir():
            continue
        for words_file in sorted(sub.glob("*.words.json")):
            try:
                raw = words_file.read_text(encoding="utf-8")
                data = json.loads(raw)
            except (OSError, json.JSONDecodeError):
                continue

            # Handle both list and dict (with "words" key) formats
            if isinstance(data, list):
                word_list = data
            elif isinstance(data, dict):
                word_list = data.get("words") or []
            else:
                continue

            words = [entry["w"] for entry in word_list if isinstance(entry, dict) and entry.get("w")]
            if words:
                file_texts.append(" ".join(words))

    if not file_texts:
        return None

    return "\n\n".join(file_texts)


# ---------------------------------------------------------------------------
# Background job helpers
# ---------------------------------------------------------------------------

def _update_job(slug: str, job_id: int, **fields):
    """Update fields on an ai_analysis row."""
    if not fields:
        return
    db = get_db(slug)
    try:
        _ensure_ai_table(db)
        cols = ", ".join(f"{k}=?" for k in fields)
        db.execute(
            f"UPDATE ai_analysis SET {cols} WHERE id=?",
            (*fields.values(), job_id),
        )
        db.commit()
    finally:
        db.close()


def _run_analysis(slug: str, job_id: int, analysis_type: str):
    """Background thread: run the AI analysis and save results to DB."""
    _update_job(slug, job_id, status="running")

    try:
        transcript_text = _collect_transcript_text(slug)
        if not transcript_text:
            _update_job(slug, job_id, status="error",
                        error_msg="No se encontró ningún transcript en el proyecto.")
            return

        # Detect language from available words files (use first detected language,
        # fall back to 'es' if not determined).
        language = _detect_language(slug) or "es"

        if analysis_type == "full":
            result = ai_engine.analyze_episode(transcript_text, language)
            notes = result.get("notes") or {}
            clips_list = result.get("clips") or []
            _update_job(
                slug, job_id,
                status="done",
                summary=notes.get("summary"),
                highlights=json.dumps(notes.get("highlights") or [], ensure_ascii=False),
                clips=json.dumps(clips_list, ensure_ascii=False),
            )

        elif analysis_type == "notes":
            result = ai_engine.regenerate_notes(transcript_text, language)
            notes = result.get("notes") or {}
            _update_job(
                slug, job_id,
                status="done",
                summary=notes.get("summary"),
                highlights=json.dumps(notes.get("highlights") or [], ensure_ascii=False),
            )

        elif analysis_type == "clips":
            clips_list = ai_engine.regenerate_clips(transcript_text, language)
            _update_job(
                slug, job_id,
                status="done",
                clips=json.dumps(clips_list, ensure_ascii=False),
            )

        else:
            _update_job(slug, job_id, status="error",
                        error_msg=f"Tipo de análisis desconocido: {analysis_type}")

    except Exception as exc:
        _update_job(slug, job_id, status="error", error_msg=str(exc)[:500])


def _detect_language(slug: str) -> str | None:
    """Read language from the first available *.words.json dict-format file."""
    media_dir = PROJECTS_DIR / slug / "media"
    if not media_dir.is_dir():
        return None
    for subdir in ("video", "audio"):
        sub = media_dir / subdir
        if not sub.is_dir():
            continue
        for words_file in sorted(sub.glob("*.words.json")):
            try:
                data = json.loads(words_file.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    lang = data.get("language")
                    if lang:
                        return lang.lower()
            except (OSError, json.JSONDecodeError):
                continue
    return None


def _start_analysis(slug: str, analysis_type: str) -> dict:
    """Create a pending ai_analysis row, spawn a daemon thread, return serialized job."""
    db = get_db(slug)
    try:
        _ensure_ai_table(db)
        cur = db.execute(
            "INSERT INTO ai_analysis (type, status) VALUES (?, 'pending')",
            (analysis_type,),
        )
        db.commit()
        job_id = cur.lastrowid
        row = db.execute("SELECT * FROM ai_analysis WHERE id=?", (job_id,)).fetchone()
    finally:
        db.close()

    t = threading.Thread(
        target=_run_analysis,
        args=(slug, job_id, analysis_type),
        daemon=True,
        name=f"ai-{analysis_type}-{job_id}",
    )
    t.start()

    return _serialize_analysis(row)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@bp.post("/api/projects/<slug>/ai/analyze")
@require_auth
def analyze_episode(slug):
    """Trigger full AI analysis (notes + clips)."""
    job = _start_analysis(slug, "full")
    return jsonify(job), 201


@bp.post("/api/projects/<slug>/ai/regenerate-notes")
@require_auth
def regenerate_notes(slug):
    """Trigger notes-only AI analysis."""
    job = _start_analysis(slug, "notes")
    return jsonify(job), 201


@bp.post("/api/projects/<slug>/ai/regenerate-clips")
@require_auth
def regenerate_clips(slug):
    """Trigger clips-only AI analysis."""
    job = _start_analysis(slug, "clips")
    return jsonify(job), 201


@bp.get("/api/projects/<slug>/ai/results")
@require_auth
def get_ai_results(slug):
    """Return the latest notes + clips + any active (pending/running) job."""
    db = get_db(slug)
    try:
        _ensure_ai_table(db)

        # Latest done job that has notes (full or notes type)
        latest_notes = db.execute(
            "SELECT * FROM ai_analysis "
            "WHERE type IN ('full', 'notes') AND status='done' "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()

        # Latest done job that has clips (full or clips type)
        latest_clips = db.execute(
            "SELECT * FROM ai_analysis "
            "WHERE type IN ('full', 'clips') AND status='done' "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()

        # Any active job (pending or running)
        active_job = db.execute(
            "SELECT * FROM ai_analysis "
            "WHERE status IN ('pending', 'running') "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()

    finally:
        db.close()

    return jsonify({
        "notes": _serialize_analysis(latest_notes) if latest_notes else None,
        "clips": _serialize_analysis(latest_clips) if latest_clips else None,
        "active_job": _serialize_analysis(active_job) if active_job else None,
    })


@bp.get("/api/projects/<slug>/ai/show-notes")
def get_show_notes(slug):
    """Public endpoint for prePod sync. Protected by X-PodPod-Secret or Bearer token."""
    got = (
        request.headers.get("X-PodPod-Secret")
        or request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    )
    if got != INTEGRATION_SECRET:
        return jsonify({"error": "no autorizado"}), 401

    db = get_db(slug)
    try:
        _ensure_ai_table(db)
        latest = db.execute(
            "SELECT * FROM ai_analysis "
            "WHERE type IN ('full', 'notes') AND status='done' "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()
    finally:
        db.close()

    if not latest:
        return jsonify({"error": "no hay notas disponibles para este proyecto"}), 404

    row = _serialize_analysis(latest)
    return jsonify({
        "summary": row["summary"],
        "highlights": row["highlights"],
        "generated_at": row["created_at"],
        "model": row["model"],
    })
