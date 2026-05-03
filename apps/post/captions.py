"""
Auto-generated captions (subtitles) using OpenAI Whisper (CPU). Each job
runs ffmpeg to extract a mono 16kHz wav from the source media, then
spawns `whisper` with the chosen language and writes an SRT sidecar next
to the media file (`<filename>.<lang>.srt`).

Whisper CPU is slow (~0.5-1x realtime) so jobs run in a background thread
and the frontend polls a job row for status.
"""

import json
import os
import shutil
import subprocess
import threading
from pathlib import Path

from flask import Blueprint, abort, jsonify, request, send_file

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


def _words_filename_for(mf_row, language):
    base = mf_row["filename"]
    lang = (language or "auto").lower()
    return f"{base}.{lang}.words.json"


def _extract_words_from_whisper_json(whisper_json: dict) -> list[dict]:
    """Whisper's JSON output (with --word_timestamps True) shape:
        {"text": "...", "segments": [{"id": 0, "start": 0.0, "end": 3.2,
                                       "text": "...",
                                       "words": [{"word": " hola", "start": 0.0,
                                                  "end": 0.4, "probability": 0.9}, ...]}, ...]}
    We flatten to a single list, normalize whitespace on the word, drop empty
    entries, and round timestamps to 3 decimals to keep the sidecar small.
    """
    out: list[dict] = []
    for seg in whisper_json.get("segments") or []:
        for w in (seg.get("words") or []):
            text = (w.get("word") or "").strip()
            if not text:
                continue
            try:
                start = float(w.get("start") or 0)
                end = float(w.get("end") or start)
            except (TypeError, ValueError):
                continue
            if end < start:
                end = start
            entry = {
                "w": text,
                "s": round(start, 3),
                "e": round(end, 3),
            }
            prob = w.get("probability")
            if prob is not None:
                try:
                    entry["p"] = round(float(prob), 2)
                except (TypeError, ValueError):
                    pass
            out.append(entry)
    return out


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

        # Use a postPod-owned cache for the Whisper model checkpoints. The
        # container's $HOME/.cache may be read-only, so the default download
        # location fails with EROFS. Fixed location => downloaded once, reused
        # for all subsequent jobs.
        from config import BASE_DIR
        whisper_cache = BASE_DIR / ".whisper_models"
        whisper_cache.mkdir(parents=True, exist_ok=True)

        # `--output_format all` writes srt + vtt + txt + json + tsv at once.
        # `--word_timestamps True` includes per-word `start`/`end` inside the
        # JSON output, which is what powers the transcript editor.
        cmd = [
            "whisper", str(wav_path),
            "--model", model or DEFAULT_MODEL,
            "--model_dir", str(whisper_cache),
            "--output_format", "all",
            "--output_dir", str(work_dir),
            "--device", "cpu",
            "--fp16", "False",
            "--word_timestamps", "True",
        ]
        if language and language != "auto":
            cmd += ["--language", language]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        if proc.returncode != 0:
            err = (proc.stderr or "").strip()
            tail = err.splitlines()[-6:] if err else ["(sin stderr)"]
            _update_job(slug, job_id, status="error",
                        error_msg="whisper: " + " | ".join(tail)[:1200])
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

        # Parse the JSON sibling and write a slim word-level sidecar.
        # Best-effort: a missing/broken JSON should not fail the whole job —
        # the SRT is still valid for the caption viewer.
        words_filename = _words_filename_for(mf, language)
        final_words = work_dir / words_filename
        whisper_json = work_dir / (wav_path.stem + ".json")
        if whisper_json.is_file():
            try:
                raw = json.loads(whisper_json.read_text(encoding="utf-8"))
                words = _extract_words_from_whisper_json(raw)
                payload = {
                    "language": (raw.get("language") or language or "").lower() or None,
                    "duration": raw.get("duration"),
                    "words": words,
                }
                if final_words.exists():
                    final_words.unlink()
                final_words.write_text(
                    json.dumps(payload, ensure_ascii=False), encoding="utf-8",
                )
            except (OSError, ValueError):
                pass
            try:
                whisper_json.unlink()
            except OSError:
                pass

        # Clean up the other sidecars whisper writes that we don't need
        # (txt, vtt, tsv) so the media folder doesn't accumulate noise.
        for ext in ("txt", "vtt", "tsv"):
            extra = work_dir / f"{wav_path.stem}.{ext}"
            try:
                if extra.is_file():
                    extra.unlink()
            except OSError:
                pass

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
    # Also remove the word-level sidecar so future regenerations don't read
    # stale word data when the user re-runs Whisper with different settings.
    words = media_dir / _words_filename_for(mf, lang)
    if words.is_file():
        try: words.unlink()
        except OSError: pass
    return jsonify({"ok": True})


@bp.put("/api/projects/<slug>/files/<int:file_id>/captions/<lang>/upload")
@require_auth
def upload_caption(slug, file_id, lang):
    """Replace an existing SRT with a user-edited version."""
    mf = _media_file_row(slug, file_id)
    if not mf:
        return jsonify({"error": "archivo no encontrado"}), 404

    f = request.files.get("srt")
    if not f:
        return jsonify({"error": "no se recibió archivo SRT"}), 400
    if not f.filename.lower().endswith(".srt"):
        return jsonify({"error": "el archivo debe ser .srt"}), 400

    content = f.read()
    if len(content) > 5 * 1024 * 1024:
        return jsonify({"error": "archivo demasiado grande (máx 5 MB)"}), 400

    media_dir = _media_path(slug, mf).parent
    target = media_dir / _srt_filename_for(mf, lang)
    target.write_bytes(content)

    _rebuild_words_json_from_srt(target, media_dir / _words_filename_for(mf, lang), lang)

    return jsonify({"ok": True, "filename": target.name})


def _rebuild_words_json_from_srt(srt_path, words_path, language):
    """Parse an SRT file and regenerate the .words.json sidecar so the
    transcript editor stays in sync with manual SRT edits."""
    import re
    try:
        text = srt_path.read_text(encoding="utf-8")
    except OSError:
        return
    blocks = re.split(r"\n\s*\n", text.strip())
    words = []
    ts_re = re.compile(
        r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})"
    )
    duration = 0.0
    for block in blocks:
        lines = block.strip().splitlines()
        if len(lines) < 3:
            continue
        m = ts_re.search(lines[1])
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0]*3600 + g[1]*60 + g[2] + g[3]/1000
        end = g[4]*3600 + g[5]*60 + g[6] + g[7]/1000
        if end > duration:
            duration = end
        segment_text = " ".join(lines[2:]).strip()
        segment_words = segment_text.split()
        if not segment_words:
            continue
        span = (end - start) / len(segment_words) if len(segment_words) > 1 else end - start
        for i, w in enumerate(segment_words):
            ws = round(start + i * span, 3)
            we = round(start + (i + 1) * span, 3)
            words.append({"w": w, "s": ws, "e": we})
    payload = {"language": language, "duration": round(duration, 3), "words": words}
    try:
        words_path.write_text(
            json.dumps(payload, ensure_ascii=False), encoding="utf-8"
        )
    except OSError:
        pass


@bp.get("/api/projects/<slug>/files/<int:file_id>/transcript")
@require_auth
def get_transcript(slug, file_id):
    """Returns the word-level transcript JSON for a given file + language.

    Response shape: {"language": "es", "duration": 123.4,
                     "words": [{"w": "hola", "s": 0.0, "e": 0.4, "p": 0.93}, ...]}
    Returns 404 if the .words.json sidecar doesn't exist (e.g. the file was
    captioned before word_timestamps was enabled — re-run captions to fix).
    """
    mf = _media_file_row(slug, file_id)
    if not mf:
        return jsonify({"error": "archivo no encontrado"}), 404
    language = (request.args.get("language") or "auto").strip().lower()
    media_dir = _media_path(slug, mf).parent
    target = media_dir / _words_filename_for(mf, language)
    if not target.is_file():
        return jsonify({
            "error": "transcript word-level no disponible",
            "hint": "regenera los captions para obtener timestamps por palabra",
        }), 404
    try:
        return send_file(str(target), mimetype="application/json")
    except OSError:
        return jsonify({"error": "no se pudo leer el transcript"}), 500
