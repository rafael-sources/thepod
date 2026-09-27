"""
Auto-generated captions (subtitles) using faster-whisper (CTranslate2).
Each job runs ffmpeg to extract a mono 16kHz wav from the source media,
then uses faster-whisper's Python API for transcription (~4x faster than
openai-whisper on CPU with int8 quantization).

Jobs run in a background thread and the frontend polls a job row for status.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from typing import Any

from flask import Blueprint, abort, jsonify, request, send_file

from auth import require_auth
from config import PROJECTS_DIR
from db import get_db


bp = Blueprint("captions", __name__)


def _ensure_project(slug):
    if not (PROJECTS_DIR / slug).exists():
        abort(404, description="proyecto no encontrado")


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

DEFAULT_MODEL = "small"


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


def _format_srt_timestamp(seconds: float) -> str:
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int(round((seconds - int(seconds)) * 1000))
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _segments_to_srt(segments: list) -> str:
    lines = []
    for i, seg in enumerate(segments, 1):
        lines.append(str(i))
        lines.append(f"{_format_srt_timestamp(seg['start'])} --> {_format_srt_timestamp(seg['end'])}")
        lines.append(seg["text"].strip())
        lines.append("")
    return "\n".join(lines)


def _segments_to_words(segments: list) -> list[dict]:
    out: list[dict] = []
    for seg in segments:
        for w in seg.get("words", []):
            text = w["word"].strip()
            if not text:
                continue
            entry = {
                "w": text,
                "s": round(w["start"], 3),
                "e": round(w["end"], 3),
            }
            if w.get("probability") is not None:
                entry["p"] = round(w["probability"], 2)
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


_fw_model_cache: dict[str, Any] = {}
_fw_model_lock = threading.Lock()


def _get_fw_model(model_name: str):
    from faster_whisper import WhisperModel
    from config import BASE_DIR
    whisper_cache = str(BASE_DIR / ".whisper_models")
    os.environ.setdefault("HF_HOME", whisper_cache)
    os.environ.setdefault("XDG_CACHE_HOME", whisper_cache)
    os.environ.setdefault("HF_HUB_CACHE", whisper_cache)
    with _fw_model_lock:
        if model_name not in _fw_model_cache:
            _fw_model_cache[model_name] = WhisperModel(
                model_name,
                device="cpu",
                compute_type="int8",
                download_root=whisper_cache,
                cpu_threads=os.cpu_count() or 4,
            )
        return _fw_model_cache[model_name]


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

        fw_model = _get_fw_model(model or DEFAULT_MODEL)
        lang_arg = language if language and language != "auto" else None
        segments_iter, info = fw_model.transcribe(
            str(wav_path),
            language=lang_arg,
            beam_size=5,
            word_timestamps=True,
            vad_filter=True,
        )

        segments = []
        for seg in segments_iter:
            words = []
            for w in seg.words or []:
                words.append({
                    "word": w.word,
                    "start": w.start,
                    "end": w.end,
                    "probability": w.probability,
                })
            segments.append({
                "start": seg.start,
                "end": seg.end,
                "text": seg.text,
                "words": words,
            })
        _update_job(slug, job_id, progress=90)

        srt_content = _segments_to_srt(segments)
        if final_srt.exists():
            final_srt.unlink()
        final_srt.write_text(srt_content, encoding="utf-8")

        words_filename = _words_filename_for(mf, language)
        final_words = work_dir / words_filename
        try:
            word_list = _segments_to_words(segments)
            detected_lang = info.language if info.language else (language or None)
            duration = info.duration if info.duration else (
                segments[-1]["end"] if segments else 0
            )
            payload = {
                "language": (detected_lang or "").lower() or None,
                "duration": round(duration, 3) if duration else None,
                "words": word_list,
            }
            if final_words.exists():
                final_words.unlink()
            final_words.write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8",
            )
        except (OSError, ValueError):
            pass

        _update_job(slug, job_id, status="done", progress=100,
                    srt_filename=srt_filename,
                    finished_at_marker=None)
        db = get_db(slug)
        try:
            db.execute("UPDATE caption_jobs SET finished_at=datetime('now') WHERE id=?", (job_id,))
            db.commit()
        finally:
            db.close()
    except Exception as e:
        _update_job(slug, job_id, status="error", error_msg=str(e)[:200])
    finally:
        try:
            if wav_path.exists():
                wav_path.unlink()
            for stale in work_dir.glob(f".{job_id}_audio.*"):
                try:
                    stale.unlink()
                except OSError:
                    pass
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
    if not (f.filename or "").lower().endswith(".srt"):
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


# ── Subtitle style ───────────────────────────────────────────────


@bp.get("/api/projects/<slug>/subtitle-style")
@require_auth
def get_subtitle_style(slug):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT * FROM subtitle_styles WHERE name='default'").fetchone()
        if not row:
            db.execute("INSERT INTO subtitle_styles (name) VALUES ('default')")
            db.commit()
            row = db.execute("SELECT * FROM subtitle_styles WHERE name='default'").fetchone()
        return jsonify({
            "id": row["id"],
            "font_family": row["font_family"],
            "font_size": row["font_size"],
            "text_color": row["text_color"],
            "outline_color": row["outline_color"],
            "background_color": row["background_color"],
            "highlight_color": row["highlight_color"],
            "position": row["position"],
        })
    finally:
        db.close()


@bp.put("/api/projects/<slug>/subtitle-style")
@require_auth
def update_subtitle_style(slug):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    allowed = {"font_family", "font_size", "text_color", "outline_color",
               "background_color", "highlight_color", "position"}
    valid_values = {
        "font_family": {"sans-serif", "serif", "mono", "display"},
        "font_size": {"small", "medium", "large"},
        "position": {"top", "center", "bottom"},
    }
    updates = {}
    for k, v in data.items():
        if k not in allowed:
            continue
        if k in valid_values and v not in valid_values[k]:
            return jsonify({"error": f"valor inválido para {k}: {v}"}), 400
        updates[k] = v
    if not updates:
        return jsonify({"error": "no hay campos válidos para actualizar"}), 400

    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM subtitle_styles WHERE name='default'").fetchone()
        if not row:
            db.execute("INSERT INTO subtitle_styles (name) VALUES ('default')")
            db.commit()
            row = db.execute("SELECT id FROM subtitle_styles WHERE name='default'").fetchone()
        set_clause = ", ".join(f"{k}=?" for k in updates)
        vals = list(updates.values()) + [row["id"]]
        db.execute(f"UPDATE subtitle_styles SET {set_clause} WHERE id=?", vals)
        db.commit()
        updated = db.execute("SELECT * FROM subtitle_styles WHERE id=?", (row["id"],)).fetchone()
        return jsonify({
            "id": updated["id"],
            "font_family": updated["font_family"],
            "font_size": updated["font_size"],
            "text_color": updated["text_color"],
            "outline_color": updated["outline_color"],
            "background_color": updated["background_color"],
            "highlight_color": updated["highlight_color"],
            "position": updated["position"],
        })
    finally:
        db.close()


# ── Word editing ─────────────────────────────────────────────────


def _regenerate_srt_from_words(words, srt_path):
    if not words:
        return
    segments = []
    current = [words[0]]
    for w in words[1:]:
        gap = w["s"] - current[-1]["e"]
        if gap > 0.8 or len(current) >= 12:
            segments.append(current)
            current = [w]
        else:
            current.append(w)
    if current:
        segments.append(current)

    lines = []
    for i, seg in enumerate(segments, 1):
        s = seg[0]["s"]
        e = seg[-1]["e"]
        text = " ".join(w["w"] for w in seg)
        lines.append(str(i))
        lines.append(f"{_format_srt_timestamp(s)} --> {_format_srt_timestamp(e)}")
        lines.append(text)
        lines.append("")
    srt_path.write_text("\n".join(lines), encoding="utf-8")


@bp.patch("/api/projects/<slug>/files/<int:file_id>/captions/<lang>/words")
@require_auth
def patch_words(slug, file_id, lang):
    _ensure_project(slug)
    mf = _media_file_row(slug, file_id)
    if not mf:
        return jsonify({"error": "archivo no encontrado"}), 404
    language = lang.strip().lower()
    media_dir = _media_path(slug, mf).parent
    words_path = media_dir / _words_filename_for(mf, language)
    if not words_path.is_file():
        return jsonify({"error": "words.json no encontrado — genera captions primero"}), 404

    data = request.get_json(silent=True) or {}
    edits = data.get("edits")
    if not isinstance(edits, list) or not edits:
        return jsonify({"error": "edits[] requerido"}), 400

    payload = json.loads(words_path.read_text(encoding="utf-8"))
    words = payload.get("words", [])
    changed = 0
    for edit in edits:
        idx = edit.get("index")
        new_word = edit.get("w")
        if not isinstance(idx, int) or idx < 0 or idx >= len(words):
            continue
        if not isinstance(new_word, str) or not new_word.strip():
            continue
        words[idx]["w"] = new_word.strip()
        changed += 1

    if changed == 0:
        return jsonify({"error": "ningún edit válido"}), 400

    payload["words"] = words
    words_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    srt_path = media_dir / _srt_filename_for(mf, language)
    if srt_path.is_file():
        _regenerate_srt_from_words(words, srt_path)

    return jsonify({"ok": True, "changed": changed})
