"""
Pre-export review (as in the Mac app): a short list of things worth checking
before rendering the video. It blocks nothing except what would make the export fail
(empty timeline or a file that is no longer there).

GET /api/projects/<slug>/export/review →
  {"items": [{"id", "level": "block"|"warn"|"info"|"optional", "text", "hint"}], "ok": bool}
"""

from __future__ import annotations

import json

from flask import Blueprint, abort, jsonify

from auth import current_user, require_auth
from config import PROJECTS_DIR
from db import get_db

bp = Blueprint("export_review", __name__)

SILENCES_KEY = "silences_cleaned_at"


def mark_silences_cleaned(db):
    """Called by the remove-silences buttons: this way the review knows it was already cleaned."""
    db.execute("INSERT OR REPLACE INTO project_meta (key, value) VALUES (?, datetime('now'))", (SILENCES_KEY,))


def _table_exists(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _words_files(media_dir, filename):
    return sorted(media_dir.glob(f"{filename}.*.words.json"))


def build_review(slug: str, username: str | None) -> list[dict]:
    items: list[dict] = []
    db = get_db(slug)
    try:
        clips = db.execute(
            "SELECT tc.id, tc.media_file_id, mf.filename, mf.original_name, mf.file_type "
            "FROM timeline_clips tc LEFT JOIN media_files mf ON mf.id = tc.media_file_id ORDER BY tc.position"
        ).fetchall()
        lane = db.execute(
            "SELECT ac.media_file_id, mf.filename, mf.original_name, mf.file_type "
            "FROM audio_lane_clips ac LEFT JOIN media_files mf ON mf.id = ac.media_file_id"
        ).fetchall()
        meta = {r["key"]: r["value"] for r in db.execute("SELECT key, value FROM project_meta")}
        cuts = db.execute("SELECT COUNT(*) FROM transcript_cuts").fetchone()[0]
        running_captions = 0
        if _table_exists(db, "caption_jobs"):
            running_captions = db.execute(
                "SELECT COUNT(*) FROM caption_jobs WHERE status IN ('pending','running')").fetchone()[0]
        ai_done = False
        if _table_exists(db, "ai_analysis"):
            ai_done = db.execute(
                "SELECT 1 FROM ai_analysis WHERE status IN ('done','running','pending') LIMIT 1").fetchone() is not None
    finally:
        db.close()

    # 1. What would make the export fail
    if not clips:
        items.append({"id": "empty", "level": "block",
                      "text": "El timeline está vacío: no hay nada que exportar.",
                      "hint": "Arrastra una grabación al timeline."})
        return items
    missing = []
    for r in list(clips) + list(lane):
        if not r["filename"]:
            missing.append("un archivo borrado")
            continue
        path = PROJECTS_DIR / slug / "media" / r["file_type"] / r["filename"]
        if not path.is_file():
            missing.append(r["original_name"] or r["filename"])
    if missing:
        names = ", ".join(sorted(set(missing))[:3])
        items.append({"id": "missing", "level": "block",
                      "text": f"Falta un archivo que usa el timeline ({names}).",
                      "hint": "Vuelve a subirlo o quita ese clip del timeline."})

    # 2. Subtitles
    av = [r for r in clips if r["file_type"] in ("video", "audio") and r["filename"]]
    words, synced = [], []
    for r in {r["media_file_id"]: r for r in av}.values():
        media_dir = PROJECTS_DIR / slug / "media" / r["file_type"]
        for f in _words_files(media_dir, r["filename"]):
            words.append(f)
            try:
                synced.append(bool(json.loads(f.read_text(encoding="utf-8")).get("synced")))
            except (OSError, ValueError):
                synced.append(False)
    if running_captions:
        items.append({"id": "captions_running", "level": "warn",
                      "text": "Los subtítulos todavía se están generando.",
                      "hint": "Espera a que terminen si quieres que salgan en el video."})
    elif not words:
        items.append({"id": "no_captions", "level": "optional",
                      "text": "No hay subtítulos: el video sale sin ellos.",
                      "hint": "En Archivos, toca el micrófono 🎙 de la grabación."})
    elif not all(synced):
        items.append({"id": "captions_sync", "level": "warn",
                      "text": "Los subtítulos no están ajustados a la voz: pueden salir antes de que se escuche.",
                      "hint": "Vuelve a generarlos; ahora se ajustan solos."})

    # 3. Silences
    if not meta.get(SILENCES_KEY) and not cuts:
        items.append({"id": "silences", "level": "optional",
                      "text": "No se quitaron los silencios largos.",
                      "hint": "Usa el botón «🔇 Silencios» de arriba."})

    # 4. AI (only once per episode)
    if words and not ai_done:
        items.append({"id": "ai", "level": "optional",
                      "text": "La IA todavía no leyó el episodio (momentos y notas).",
                      "hint": "Se hace una sola vez por episodio."})

    # 5. Plan
    try:
        from plans import limits_for
        lim = limits_for(username)
        if lim.get("max_height"):
            items.append({"id": "plan", "level": "info",
                          "text": f"Tu plan {lim['name']} exporta hasta {lim['max_height']}p.",
                          "hint": "Para 1080p o 4K, mira los planes."})
    except Exception:
        pass
    return items


@bp.get("/api/projects/<slug>/export/review")
@require_auth
def export_review(slug):
    if not (PROJECTS_DIR / slug).exists():
        abort(404, description="proyecto no encontrado")
    items = build_review(slug, current_user())
    return jsonify({"items": items, "ok": not any(i["level"] == "block" for i in items)})
