import json
import os
import shutil
import subprocess
import uuid
from pathlib import Path

from flask import Blueprint, abort, jsonify, request

from auth import require_auth
from config import ALLOWED_EXTS, GLOBAL_DIR, MEDIA_TYPES, PROJECTS_DIR, ext_to_type
from db import get_db
from timeline_api import recalc_after_external_change, snapshot_clips_and_moments


bp = Blueprint("files", __name__)


def _probe_duration(path: Path) -> float | None:
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "quiet", "-print_format", "json",
                "-show_format", "-show_streams", str(path),
            ],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return None
        info = json.loads(result.stdout)
        fmt_dur = info.get("format", {}).get("duration")
        dur = float(fmt_dur) if fmt_dur is not None else None
        if dur and dur > 86400:
            for s in info.get("streams", []):
                if s.get("codec_type") == "audio" and s.get("duration"):
                    audio_dur = float(s["duration"])
                    if audio_dur < 86400:
                        return audio_dur
        return dur
    except (subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return None


def _remux_if_broken_mp4(path: Path) -> bool:
    """Safari MediaRecorder writes mp4 with wildly wrong video-stream duration.
    Remux in-place with ffmpeg -c copy to fix the container metadata.
    Returns True if the file was remuxed."""
    if path.suffix.lower() != ".mp4":
        return False
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json",
             "-show_format", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        if probe.returncode != 0:
            return False
        fmt_dur = json.loads(probe.stdout).get("format", {}).get("duration")
        if fmt_dur is None or float(fmt_dur) < 86400:
            return False
        fixed = path.with_suffix(".fixed.mp4")
        r = subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", str(path),
             "-c", "copy", "-movflags", "+faststart", str(fixed)],
            capture_output=True, text=True, timeout=600,
        )
        if r.returncode == 0 and fixed.exists() and fixed.stat().st_size > 0:
            path.unlink()
            fixed.rename(path)
            return True
        fixed.unlink(missing_ok=True)
        return False
    except (subprocess.SubprocessError, json.JSONDecodeError, ValueError, OSError):
        return False


def _thumbnail_path(video_path: Path) -> Path:
    return video_path.with_suffix(video_path.suffix + ".thumb.jpg")


def _thumbnail_end_path(video_path: Path) -> Path:
    return video_path.with_suffix(video_path.suffix + ".thumb_end.jpg")


def _peaks_path(media_path: Path) -> Path:
    return media_path.with_suffix(media_path.suffix + ".peaks.json")


def _generate_waveform(media_path: Path, duration: float | None) -> bool:
    """Decode mono 8kHz PCM via ffmpeg and write a sidecar JSON with ~10 peaks/s."""
    if not duration or duration <= 0:
        return False
    try:
        out_path = _peaks_path(media_path)
        sample_rate = 8000
        peaks_per_second = 10
        target_peaks = max(10, int(round(duration * peaks_per_second)))

        proc = subprocess.run(
            [
                "ffmpeg", "-v", "error", "-i", str(media_path),
                "-ac", "1", "-ar", str(sample_rate),
                "-map", "0:a:0?",
                "-f", "s16le", "-",
            ],
            capture_output=True, timeout=600,
        )
        if proc.returncode != 0 or not proc.stdout:
            return False

        pcm = proc.stdout
        total_samples = len(pcm) // 2
        if total_samples < target_peaks:
            return False

        import array
        samples = array.array("h")
        samples.frombytes(pcm)

        bucket = max(1, total_samples // target_peaks)
        peaks = []
        for i in range(0, total_samples, bucket):
            chunk = samples[i:i + bucket]
            if not chunk:
                break
            peak = 0
            for s in chunk:
                a = -s if s < 0 else s
                if a > peak:
                    peak = a
            peaks.append(round(peak / 32768.0, 4))

        payload = {
            "peaks": peaks,
            "sample_rate": sample_rate,
            "duration": duration,
        }
        out_path.write_text(json.dumps(payload, separators=(",", ":")))
        return True
    except (subprocess.SubprocessError, OSError, ValueError):
        return False


def _generate_thumbnail(video_path: Path, duration: float | None) -> bool:
    """Generate a 320-wide JPG thumbnail at ~10% into the video."""
    try:
        t = max(0.1, min(1.0, (duration or 2.0) * 0.1))
        out = _thumbnail_path(video_path)
        proc = subprocess.run(
            [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-ss", f"{t:.2f}", "-i", str(video_path),
                "-vframes", "1",
                "-vf", "scale=320:-2",
                "-q:v", "4",
                str(out),
            ],
            capture_output=True, text=True, timeout=30,
        )
        return proc.returncode == 0 and out.exists()
    except (subprocess.SubprocessError, OSError):
        return False


def _generate_end_thumbnail(video_path: Path, duration: float | None) -> bool:
    """Generate a 320-wide JPG thumbnail at ~the last frame of the video."""
    try:
        if not duration or duration <= 0.3:
            return False
        # Seek to a bit before the end to avoid empty frames at EOF
        t = max(0.0, float(duration) - 0.2)
        out = _thumbnail_end_path(video_path)
        proc = subprocess.run(
            [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-ss", f"{t:.2f}", "-i", str(video_path),
                "-vframes", "1",
                "-vf", "scale=320:-2",
                "-q:v", "4",
                str(out),
            ],
            capture_output=True, text=True, timeout=30,
        )
        return proc.returncode == 0 and out.exists()
    except (subprocess.SubprocessError, OSError):
        return False


def _project_file_url(slug, file_type, filename):
    return f"/media/projects/{slug}/{file_type}/{filename}"


def _global_file_url(file_type, filename):
    return f"/media/global/{file_type}/{filename}"


def _project_thumb_url(slug, file_type, filename):
    return f"/media/projects/{slug}/{file_type}/{filename}.thumb.jpg"


def _project_thumb_end_url(slug, file_type, filename):
    return f"/media/projects/{slug}/{file_type}/{filename}.thumb_end.jpg"


def _global_thumb_url(file_type, filename):
    return f"/media/global/{file_type}/{filename}.thumb.jpg"


def _project_peaks_url(slug, file_type, filename):
    return f"/media/projects/{slug}/{file_type}/{filename}.peaks.json"


def _global_peaks_url(file_type, filename):
    return f"/media/global/{file_type}/{filename}.peaks.json"


def _ensure_project(slug):
    if not (PROJECTS_DIR / slug).exists():
        abort(404, description="proyecto no encontrado")


@bp.get("/api/projects/<slug>/files")
@require_auth
def list_files(slug):
    _ensure_project(slug)
    db = get_db(slug)
    rows = db.execute(
        "SELECT id, filename, original_name, file_type, duration, size_bytes "
        "FROM media_files ORDER BY created_at DESC"
    ).fetchall()
    db.close()
    out = []
    for r in rows:
        entry = {**dict(r), "url": _project_file_url(slug, r["file_type"], r["filename"])}
        src_dir = PROJECTS_DIR / slug / "media" / r["file_type"]
        if r["file_type"] == "video":
            if (src_dir / f"{r['filename']}.thumb.jpg").is_file():
                entry["thumbnail_url"] = _project_thumb_url(slug, r["file_type"], r["filename"])
            if (src_dir / f"{r['filename']}.thumb_end.jpg").is_file():
                entry["thumbnail_end_url"] = _project_thumb_end_url(slug, r["file_type"], r["filename"])
        if r["file_type"] in ("video", "audio"):
            if (src_dir / f"{r['filename']}.peaks.json").is_file():
                entry["peaks_url"] = _project_peaks_url(slug, r["file_type"], r["filename"])
        out.append(entry)
    return jsonify(out)


@bp.post("/api/projects/<slug>/files")
@require_auth
def upload_file(slug):
    _ensure_project(slug)
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido en campo 'file'"}), 400

    original_name = f.filename
    ext = Path(original_name).suffix.lower()
    file_type = ext_to_type(ext)
    if not file_type:
        return jsonify({
            "error": f"extensión no soportada: {ext}",
            "allowed": {k: sorted(v) for k, v in ALLOWED_EXTS.items()},
        }), 400

    filename = f"{uuid.uuid4().hex}{ext}"
    dest_dir = PROJECTS_DIR / slug / "media" / file_type
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename
    f.save(str(dest))

    _remux_if_broken_mp4(dest)
    size_bytes = dest.stat().st_size
    duration = _probe_duration(dest) if file_type in ("video", "audio") else None

    thumbnail_url = None
    thumbnail_end_url = None
    if file_type == "video":
        if _generate_thumbnail(dest, duration):
            thumbnail_url = _project_thumb_url(slug, file_type, filename)
        if _generate_end_thumbnail(dest, duration):
            thumbnail_end_url = _project_thumb_end_url(slug, file_type, filename)

    peaks_url = None
    if file_type in ("video", "audio"):
        if _generate_waveform(dest, duration):
            peaks_url = _project_peaks_url(slug, file_type, filename)

    db = get_db(slug)
    cur = db.execute(
        "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
        "VALUES (?, ?, ?, ?, ?)",
        (filename, original_name, file_type, duration, size_bytes),
    )
    db.commit()
    file_id = cur.lastrowid
    db.close()

    return jsonify({
        "id": file_id,
        "filename": filename,
        "original_name": original_name,
        "file_type": file_type,
        "duration": duration,
        "size_bytes": size_bytes,
        "url": _project_file_url(slug, file_type, filename),
        "thumbnail_url": thumbnail_url,
        "thumbnail_end_url": thumbnail_end_url,
        "peaks_url": peaks_url,
    }), 201


@bp.delete("/api/projects/<slug>/files/<int:file_id>")
@require_auth
def delete_file(slug, file_id):
    _ensure_project(slug)
    db = get_db(slug)
    row = db.execute(
        "SELECT filename, file_type FROM media_files WHERE id=?", (file_id,)
    ).fetchone()
    if not row:
        db.close()
        return jsonify({"error": "archivo no encontrado"}), 404
    path = PROJECTS_DIR / slug / "media" / row["file_type"] / row["filename"]
    if path.exists():
        path.unlink()
    for sidecar in (_thumbnail_path(path), _peaks_path(path)):
        if sidecar.exists():
            sidecar.unlink()
    old_clips, old_moments = snapshot_clips_and_moments(db)
    db.execute("DELETE FROM media_files WHERE id=?", (file_id,))
    recalc_after_external_change(db, old_clips, old_moments)
    db.commit()
    db.close()
    return jsonify({"ok": True})


@bp.post("/api/projects/<slug>/files/import-global")
@require_auth
def import_global(slug):
    """
    Copy a file from the global library into this project's local media
    folder so it becomes a regular media_file with an ID usable by ops
    (text_overlay sounds, audio_mix, etc). Idempotent on (filename, file_type):
    returns the existing row if the filename was already imported.
    """
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    filename = (data.get("filename") or "").strip()
    file_type = (data.get("file_type") or "").strip()
    if not filename or file_type not in MEDIA_TYPES:
        return jsonify({"error": "filename y file_type (video|audio|image) requeridos"}), 400

    src = GLOBAL_DIR / file_type / filename
    if not src.is_file():
        return jsonify({"error": "archivo global no encontrado"}), 404

    dest_dir = PROJECTS_DIR / slug / "media" / file_type
    dest_dir.mkdir(parents=True, exist_ok=True)

    db = get_db(slug)
    try:
        existing = db.execute(
            "SELECT id, filename, original_name, file_type, duration, size_bytes "
            "FROM media_files WHERE filename=? AND file_type=?",
            (filename, file_type),
        ).fetchone()
        if existing:
            return jsonify({
                "id": existing["id"],
                "filename": existing["filename"],
                "original_name": existing["original_name"],
                "file_type": existing["file_type"],
                "duration": existing["duration"],
                "size_bytes": existing["size_bytes"],
                "url": _project_file_url(slug, existing["file_type"], existing["filename"]),
                "imported": False,
            })

        dest = dest_dir / filename
        if not dest.exists():
            shutil.copy2(str(src), str(dest))
            # Copy sidecars if present (peaks, thumb)
            for side_src, side_dest in (
                (_thumbnail_path(src), _thumbnail_path(dest)),
                (_peaks_path(src), _peaks_path(dest)),
            ):
                if side_src.exists():
                    try: shutil.copy2(str(side_src), str(side_dest))
                    except OSError: pass

        size_bytes = dest.stat().st_size
        duration = _probe_duration(dest) if file_type in ("video", "audio") else None
        cur = db.execute(
            "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
            "VALUES (?, ?, ?, ?, ?)",
            (filename, filename, file_type, duration, size_bytes),
        )
        db.commit()
        return jsonify({
            "id": cur.lastrowid,
            "filename": filename,
            "original_name": filename,
            "file_type": file_type,
            "duration": duration,
            "size_bytes": size_bytes,
            "url": _project_file_url(slug, file_type, filename),
            "imported": True,
        }), 201
    finally:
        db.close()


@bp.post("/api/projects/<slug>/files/<int:file_id>/make-global")
@require_auth
def make_global(slug, file_id):
    _ensure_project(slug)
    db = get_db(slug)
    row = db.execute(
        "SELECT filename, file_type, original_name FROM media_files WHERE id=?",
        (file_id,),
    ).fetchone()
    if not row:
        db.close()
        return jsonify({"error": "archivo no encontrado"}), 404

    src = PROJECTS_DIR / slug / "media" / row["file_type"] / row["filename"]
    dest_dir = GLOBAL_DIR / row["file_type"]
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / row["filename"]

    if not src.exists():
        db.execute("DELETE FROM media_files WHERE id=?", (file_id,))
        db.commit()
        db.close()
        return jsonify({"error": "archivo fuente desaparecido, registro limpiado"}), 410

    # If dest somehow already exists, keep original name unique with a new uuid
    if dest.exists():
        dest = dest_dir / f"{uuid.uuid4().hex}{Path(row['filename']).suffix}"
    shutil.move(str(src), str(dest))

    # Move sidecars too if present
    for src_sidecar, dest_sidecar in (
        (_thumbnail_path(src), _thumbnail_path(dest)),
        (_peaks_path(src), _peaks_path(dest)),
    ):
        if src_sidecar.exists():
            try:
                shutil.move(str(src_sidecar), str(dest_sidecar))
            except OSError:
                pass

    old_clips, old_moments = snapshot_clips_and_moments(db)
    db.execute("DELETE FROM media_files WHERE id=?", (file_id,))
    recalc_after_external_change(db, old_clips, old_moments)
    db.commit()
    db.close()
    return jsonify({
        "ok": True,
        "url": _global_file_url(row["file_type"], dest.name),
    })


@bp.post("/api/projects/<slug>/regenerate-thumbnails")
@require_auth
def regenerate_thumbnails(slug):
    """Generate missing thumbnails for project videos and globals.
    Body (optional): {"force": true} regenerates even if thumb exists."""
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    force = bool(data.get("force", False))

    generated = 0
    skipped = 0
    failed = 0

    # Project videos
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT id, filename, file_type, duration FROM media_files WHERE file_type='video'"
        ).fetchall()
        rows = [dict(r) for r in rows]
    finally:
        db.close()

    for r in rows:
        path = PROJECTS_DIR / slug / "media" / r["file_type"] / r["filename"]
        if not path.exists():
            continue
        thumb = _thumbnail_path(path)
        if thumb.exists() and not force:
            skipped += 1
            continue
        if _generate_thumbnail(path, r["duration"]):
            generated += 1
        else:
            failed += 1

    # Globals
    gd = GLOBAL_DIR / "video"
    if gd.exists():
        for entry in sorted(gd.iterdir()):
            if not entry.is_file() or entry.name.endswith(".thumb.jpg"):
                continue
            thumb = _thumbnail_path(entry)
            if thumb.exists() and not force:
                skipped += 1
                continue
            if _generate_thumbnail(entry, _probe_duration(entry)):
                generated += 1
            else:
                failed += 1

    return jsonify({
        "generated": generated,
        "skipped": skipped,
        "failed": failed,
    })


@bp.get("/api/global/files")
@require_auth
def list_global_files():
    GLOBAL_DIR.mkdir(parents=True, exist_ok=True)
    out = []
    for file_type in MEDIA_TYPES:
        d = GLOBAL_DIR / file_type
        if not d.exists():
            continue
        for entry in sorted(d.iterdir()):
            if not entry.is_file():
                continue
            if entry.name.endswith(".thumb.jpg") or entry.name.endswith(".peaks.json"):
                continue  # sidecar
            ext = entry.suffix.lower()
            if ext not in ALLOWED_EXTS.get(file_type, set()):
                continue  # skip LICENSES.md / readmes / anything non-media
            stat = entry.stat()
            thumb = None
            peaks = None
            if file_type == "video":
                if _thumbnail_path(entry).is_file():
                    thumb = _global_thumb_url(file_type, entry.name)
            if file_type in ("video", "audio"):
                if _peaks_path(entry).is_file():
                    peaks = _global_peaks_url(file_type, entry.name)
            out.append({
                "filename": entry.name,
                "original_name": entry.name,
                "file_type": file_type,
                "duration": _probe_duration(entry) if file_type in ("video", "audio") else None,
                "size_bytes": stat.st_size,
                "url": _global_file_url(file_type, entry.name),
                "thumbnail_url": thumb,
                "peaks_url": peaks,
            })
    return jsonify(out)
