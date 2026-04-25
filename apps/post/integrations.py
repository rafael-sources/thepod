"""
Incoming app-to-app integrations. These endpoints are NOT protected by user
sessions — they're for server-to-server calls from prePod / prodPod. They
require a shared secret (`INTEGRATION_SECRET`) in the `X-PodPod-Secret`
header.
"""

import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

from flask import Blueprint, jsonify, request

from config import ALLOWED_EXTS, INTEGRATION_SECRET, PROJECTS_DIR, ext_to_type
from db import get_db
from files import _generate_thumbnail, _generate_waveform, _peaks_path, _probe_duration, _project_file_url
from projects import _create_project_internal, _read_meta, find_project_by_shared_id


bp = Blueprint("integrations", __name__)


def _require_shared_secret():
    got = request.headers.get("X-PodPod-Secret") or request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if got != INTEGRATION_SECRET:
        return jsonify({"error": "no autorizado"}), 401
    return None


def _summarize_project(meta):
    if not meta:
        return None
    return {
        "slug": meta.get("slug"),
        "name": meta.get("name"),
        "shared_project_id": meta.get("shared_project_id"),
        "created_at": meta.get("created_at"),
        "source": meta.get("source"),
    }


@bp.get("/api/integrations/status")
def integration_status():
    """Return info about a project linked by shared_project_id, or 404."""
    err = _require_shared_secret()
    if err:
        return err
    spid = request.args.get("shared_project_id")
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400
    meta = find_project_by_shared_id(spid)
    if not meta:
        return jsonify({"found": False}), 404
    return jsonify({"found": True, "project": _summarize_project(meta)})


@bp.post("/api/integrations/prepod/import")
def import_from_prepod():
    """
    Create a postPod project from a prePod episode payload. If a project with
    the same shared_project_id already exists, return its info (idempotent).
    """
    err = _require_shared_secret()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    if (data.get("source_app") or "").lower() != "prepod":
        return jsonify({"error": "source_app inválido"}), 400

    spid = data.get("shared_project_id")
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400

    existing = find_project_by_shared_id(spid)
    if existing:
        return jsonify({"project": _summarize_project(existing), "created": False}), 200

    podcast = data.get("podcast") or {}
    episode = data.get("episode") or {}

    podcast_name = (podcast.get("name") or "").strip() or "Podcast"
    ep_num = episode.get("number")
    ep_title = (episode.get("title") or "").strip()
    if ep_num and ep_title:
        project_name = f"{podcast_name} · Ep {ep_num}: {ep_title}"
    elif ep_title:
        project_name = f"{podcast_name} · {ep_title}"
    else:
        project_name = podcast_name

    # Minimal source snapshot: who/what/when. Full payload preserved for reference.
    source_info = {
        "app": "prepod",
        "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "podcast": {
            "name": podcast_name,
            "slug": podcast.get("slug"),
            "description": podcast.get("description"),
            "branding": podcast.get("branding"),
        },
        "episode": {
            "id": episode.get("id"),
            "number": ep_num,
            "title": ep_title,
            "description": episode.get("description"),
            "scheduled_date": episode.get("scheduled_date"),
            "duration_estimate": episode.get("duration_estimate"),
            "script": episode.get("script") or [],
            "ideas": episode.get("ideas") or [],
            "links": episode.get("links") or [],
        },
    }

    meta = _create_project_internal(
        name=project_name,
        shared_project_id=spid,
        source_info=source_info,
    )
    return jsonify({"project": _summarize_project(meta), "created": True}), 201


COMPOSITE_MARKER = "[composite_podcast_hstack]"


def _convert_webm_to_mp3(src_webm: Path, dest_mp3: Path) -> bool:
    """Convert a webm/opus audio track (from prodPod soundboard) to mp3 so the
    audio lane can use it straight. Returns True on success."""
    try:
        proc = subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-i", str(src_webm),
             "-vn", "-acodec", "libmp3lame", "-b:a", "128k",
             str(dest_mp3)],
            capture_output=True, text=True, timeout=120,
        )
        return proc.returncode == 0 and dest_mp3.exists() and dest_mp3.stat().st_size > 0
    except (subprocess.SubprocessError, OSError):
        return False


def _detect_non_silent_ranges(mp3_path: Path, total_duration: float,
                              threshold_db: float = -32.0,
                              min_silence: float = 0.25) -> list:
    """
    Use ffmpeg silencedetect to find non-silent ranges inside an audio file.
    Returns list of (start, end) tuples in seconds. If no silences detected
    the whole file is returned as one range.
    """
    import re as _re
    try:
        proc = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostats",
             "-i", str(mp3_path),
             "-af", f"silencedetect=noise={threshold_db}dB:d={min_silence}",
             "-f", "null", "-"],
            capture_output=True, text=True, timeout=180,
        )
    except (subprocess.SubprocessError, OSError):
        return [(0.0, total_duration)]
    starts = [float(m.group(1)) for m in _re.finditer(r"silence_start:\s*([\d.]+)", proc.stderr)]
    ends   = [float(m.group(1)) for m in _re.finditer(r"silence_end:\s*([\d.]+)",   proc.stderr)]
    silences = list(zip(starts, ends))
    if not silences:
        return [(0.0, total_duration)]
    non_silent = []
    cursor = 0.0
    for s, e in silences:
        if s > cursor + 0.01:
            non_silent.append((cursor, s))
        cursor = e
    if cursor < total_duration - 0.01:
        non_silent.append((cursor, total_duration))
    # Pad each range a bit so attacks aren't clipped (20ms leading, 80ms trail).
    padded = []
    for s, e in non_silent:
        padded.append((max(0.0, s - 0.02), min(total_duration, e + 0.08)))
    return padded


def _import_soundboard_to_lane(slug: str, webm_dest: Path, hinted_dur: float,
                               label: str) -> dict:
    """
    Convert a prodPod soundboard webm to mp3, register the full file as a
    media_file (for reference), then SPLIT it by silence and add each
    non-silent burst as its own audio_lane_clip at its real trigger time —
    this way the user sees each sound at the moment it was pressed, not all
    stacked at t=0.
    """
    audio_dir = PROJECTS_DIR / slug / "media" / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    full_mp3 = webm_dest.stem + ".mp3"
    full_path = audio_dir / full_mp3
    ok = _convert_webm_to_mp3(webm_dest, full_path)
    try: webm_dest.unlink()
    except OSError: pass
    if not ok:
        return {"error": "no se pudo convertir el soundboard a mp3"}

    total_dur = _probe_duration(full_path) or hinted_dur
    if total_dur <= 0:
        total_dur = hinted_dur or 0

    ranges = _detect_non_silent_ranges(full_path, total_dur)

    db = get_db(slug)
    clips_created = []
    try:
        # Register the full-length file so the user can still refer to it if
        # they want the raw soundboard track; we don't lane-place the full one.
        cur = db.execute(
            "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
            "VALUES (?, ?, ?, ?, ?)",
            (full_mp3, label + " (completo)", "audio", total_dur, full_path.stat().st_size),
        )
        full_id = cur.lastrowid

        for idx, (s, e) in enumerate(ranges):
            clip_dur = e - s
            if clip_dur < 0.05:
                continue
            piece_name = f"{webm_dest.stem}_t{int(s*1000):06d}.mp3"
            piece_path = audio_dir / piece_name
            try:
                subprocess.run(
                    ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                     "-ss", f"{s:.3f}", "-to", f"{e:.3f}",
                     "-i", str(full_path),
                     "-acodec", "libmp3lame", "-b:a", "128k",
                     str(piece_path)],
                    capture_output=True, timeout=60,
                )
            except (subprocess.SubprocessError, OSError):
                continue
            if not piece_path.exists() or piece_path.stat().st_size == 0:
                continue
            piece_dur = _probe_duration(piece_path) or clip_dur
            _generate_waveform(piece_path, piece_dur)
            piece_label = f"{label} · {s:.1f}s"
            pcur = db.execute(
                "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
                "VALUES (?, ?, ?, ?, ?)",
                (piece_name, piece_label, "audio", piece_dur, piece_path.stat().st_size),
            )
            pid = pcur.lastrowid
            db.execute(
                """INSERT INTO audio_lane_clips
                   (media_file_id, label, tl_start, start_offset, end_offset, volume)
                   VALUES (?, ?, ?, 0, NULL, 0.9)""",
                (pid, piece_label, s),
            )
            clips_created.append({
                "media_file_id": pid, "tl_start": s, "duration": piece_dur,
                "filename": piece_name,
            })
        db.commit()
    finally:
        db.close()

    # Waveform for the full file (for reference / inspection)
    _generate_waveform(full_path, total_dur)

    return {
        "full_file_id": full_id,
        "filename": full_mp3,
        "duration": total_dur,
        "size_bytes": full_path.stat().st_size,
        "url": _project_file_url(slug, "audio", full_mp3),
        "lane_clips_created": len(clips_created),
        "clips": clips_created,
        "added_to_audio_lane": True,
    }


def _compose_hstack_side_by_side(slug: str) -> dict | None:
    """
    If the project has 2+ participant video tracks (from prodPod), build a
    side-by-side composite via ffmpeg hstack + amix. Idempotent: regenerates
    whenever the set of source videos changes.
    Returns the new composite media_file info, or None if not enough inputs.
    """
    db = get_db(slug)
    try:
        # Source videos: everything except the previous composite itself.
        sources = db.execute(
            """SELECT id, filename, original_name, duration
               FROM media_files
               WHERE file_type='video' AND (original_name IS NULL OR original_name NOT LIKE ?)
               ORDER BY original_name""",
            (COMPOSITE_MARKER + "%",),
        ).fetchall()
        if len(sources) < 2:
            return None

        video_dir = PROJECTS_DIR / slug / "media" / "video"
        src_paths = [video_dir / r["filename"] for r in sources]
        for p in src_paths:
            if not p.is_file():
                return None

        # Remove previous composite (file + row) — regeneration is the whole point.
        old = db.execute(
            "SELECT id, filename FROM media_files WHERE original_name LIKE ?",
            (COMPOSITE_MARKER + "%",),
        ).fetchone()
        if old:
            old_path = video_dir / old["filename"]
            try: old_path.unlink()
            except OSError: pass
            for side in (old_path.with_suffix(old_path.suffix + ".thumb.jpg"),
                         old_path.with_suffix(old_path.suffix + ".peaks.json")):
                try: side.unlink()
                except OSError: pass
            db.execute("DELETE FROM media_files WHERE id=?", (old["id"],))
            db.commit()

        out_filename = f"composite_{uuid.uuid4().hex[:8]}.mp4"
        out_path = video_dir / out_filename

        # Build ffmpeg command: scale each source to same height, hstack.
        # amix'd audio from all sources. H.264/AAC in MP4 for fast encoding
        # — VP9 realtime is ~10x slower and exceeds our timeout on 4 tracks.
        n = len(src_paths)
        scale_h = 720
        cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
        for p in src_paths:
            cmd += ["-i", str(p)]
        scales = []
        for i in range(n):
            scales.append(f"[{i}:v]scale=-2:{scale_h},setsar=1[v{i}]")
        hstack_in = "".join(f"[v{i}]" for i in range(n))
        amix_in = "".join(f"[{i}:a]" for i in range(n))
        fcomplex = ";".join(scales) + ";" + \
                   f"{hstack_in}hstack=inputs={n}[vout];" + \
                   f"{amix_in}amix=inputs={n}:duration=longest:normalize=0[aout]"
        cmd += ["-filter_complex", fcomplex,
                "-map", "[vout]", "-map", "[aout]",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "24",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart",
                str(out_path)]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        except (subprocess.SubprocessError, OSError) as e:
            return {"error": f"ffmpeg compose falló: {e}"}
        if proc.returncode != 0 or not out_path.exists():
            return {"error": "ffmpeg compose no produjo salida",
                    "stderr": (proc.stderr or "")[:400]}

        duration = _probe_duration(out_path)
        size_bytes = out_path.stat().st_size
        label = f"{COMPOSITE_MARKER} {n} cámaras lado a lado"
        if _generate_thumbnail(out_path, duration):
            pass  # thumbnail sidecar generated
        _generate_waveform(out_path, duration)

        cur = db.execute(
            "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
            "VALUES (?, ?, 'video', ?, ?)",
            (out_filename, label, duration, size_bytes),
        )
        composite_id = cur.lastrowid

        # Auto-place composite on the timeline at position 0 (replacing any
        # previous composite placement so the user sees it ready to play).
        db.execute(
            "DELETE FROM timeline_clips WHERE label LIKE ?",
            (COMPOSITE_MARKER + "%",),
        )
        db.execute(
            "UPDATE timeline_clips SET position = position + 1"
        )
        db.execute(
            """INSERT INTO timeline_clips
               (position, media_file_id, label, start_offset, end_offset, track, volume)
               VALUES (0, ?, ?, 0, NULL, 1, 1.0)""",
            (composite_id, label),
        )
        db.commit()
        return {
            "id": composite_id,
            "filename": out_filename,
            "original_name": label,
            "file_type": "video",
            "duration": duration,
            "size_bytes": size_bytes,
            "url": _project_file_url(slug, "video", out_filename),
        }
    finally:
        db.close()


@bp.post("/api/integrations/prodpod/import-chapters")
def import_chapters_from_prodpod():
    """
    Receive chapter markers captured during a prodPod recording and create
    a `relative` moment for each at the right timeline_seconds.
    Body: {shared_project_id, project_name?, chapters: [{label, tl_offset_seconds}]}
    """
    err = _require_shared_secret()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    spid = (data.get("shared_project_id") or "").strip()
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400
    chapters = data.get("chapters") or []
    if not isinstance(chapters, list):
        return jsonify({"error": "chapters debe ser lista"}), 400

    meta = find_project_by_shared_id(spid)
    if not meta:
        project_name = (data.get("project_name") or "").strip() or f"Episodio {spid[:8]}"
        meta = _create_project_internal(
            name=project_name, shared_project_id=spid,
            source_info={"app": "prodpod",
                         "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                         "auto_created_by": "prodpod_chapters"},
        )
    slug = meta["slug"]

    db = get_db(slug)
    created = 0
    skipped = 0
    try:
        for c in chapters:
            try:
                off = float(c.get("tl_offset_seconds") or 0)
            except (TypeError, ValueError):
                skipped += 1; continue
            if off < 0:
                skipped += 1; continue
            label = (c.get("label") or "").strip()[:200]
            # Idempotent: skip if a moment already exists at this exact time
            # with the same label (likely re-import).
            exists = db.execute(
                "SELECT id FROM moments WHERE timeline_seconds=? AND COALESCE(label,'')=?",
                (off, label),
            ).fetchone()
            if exists:
                skipped += 1; continue
            db.execute(
                "INSERT INTO moments (type, timeline_seconds, label) VALUES ('relative', ?, ?)",
                (off, label),
            )
            created += 1
        db.commit()
    finally:
        db.close()

    return jsonify({
        "project": _summarize_project(meta),
        "created_moments": created,
        "skipped": skipped,
    }), 201


@bp.post("/api/integrations/prodpod/import-sound-triggers")
def import_sound_triggers_from_prodpod():
    """
    Receive a batch of soundboard trigger events from prodPod and place each
    one as its own audio_lane_clip at the exact tl_offset_seconds.

    Each trigger references a `filename` that must exist in the global audio
    library (postpod/global/audio/) — postPod auto-imports it into the
    project's local media on first use, then reuses the same media_file_id
    for subsequent triggers of the same sound.

    Body:
      shared_project_id (required)
      project_name      (optional, used if creating project)
      triggers: [{filename, tl_offset_seconds, participant_name}, ...]
    """
    err = _require_shared_secret()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    spid = (data.get("shared_project_id") or "").strip()
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400
    triggers = data.get("triggers") or []
    if not isinstance(triggers, list):
        return jsonify({"error": "triggers debe ser lista"}), 400

    meta = find_project_by_shared_id(spid)
    if not meta:
        project_name = (data.get("project_name") or "").strip() or f"Episodio {spid[:8]}"
        meta = _create_project_internal(
            name=project_name, shared_project_id=spid,
            source_info={"app": "prodpod",
                         "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                         "auto_created_by": "prodpod_sound_triggers"},
        )
    slug = meta["slug"]

    # Resolve filename → local media_file_id, importing from global library if
    # needed. Cache lookups so a sound triggered N times is imported once.
    from config import GLOBAL_DIR
    db = get_db(slug)
    sound_id_cache = {}
    created = 0
    skipped = 0
    try:
        for t in triggers:
            try:
                fname = (t.get("filename") or "").strip()
                off = float(t.get("tl_offset_seconds") or 0)
            except (ValueError, AttributeError):
                skipped += 1
                continue
            if not fname or off < 0:
                skipped += 1
                continue
            if fname in sound_id_cache:
                media_id = sound_id_cache[fname]
            else:
                # Try to find an already-imported local copy first.
                row = db.execute(
                    "SELECT id FROM media_files WHERE filename=? AND file_type='audio'",
                    (fname,),
                ).fetchone()
                if row:
                    media_id = row["id"]
                else:
                    # Import from global library.
                    src = GLOBAL_DIR / "audio" / fname
                    if not src.is_file():
                        # Sound not in the global library — skip with warning.
                        skipped += 1
                        sound_id_cache[fname] = None
                        continue
                    dest_dir = PROJECTS_DIR / slug / "media" / "audio"
                    dest_dir.mkdir(parents=True, exist_ok=True)
                    dest = dest_dir / fname
                    if not dest.exists():
                        import shutil as _shutil
                        _shutil.copy2(str(src), str(dest))
                        for side in (_peaks_path(src), Path(str(src) + ".thumb.jpg")):
                            if side.exists():
                                try: _shutil.copy2(str(side), str(dest_dir / side.name))
                                except OSError: pass
                    dur = _probe_duration(dest) or 0
                    if dur > 0:
                        _generate_waveform(dest, dur)
                    cur = db.execute(
                        "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
                        "VALUES (?, ?, 'audio', ?, ?)",
                        (fname, fname, dur, dest.stat().st_size),
                    )
                    media_id = cur.lastrowid
                sound_id_cache[fname] = media_id
            if media_id is None:
                continue
            label = t.get("participant_name") or fname
            db.execute(
                """INSERT INTO audio_lane_clips
                   (media_file_id, label, tl_start, start_offset, end_offset, volume)
                   VALUES (?, ?, ?, 0, NULL, 0.9)""",
                (media_id, f"{label} · {fname}", off),
            )
            created += 1
        db.commit()
    finally:
        db.close()

    return jsonify({
        "project": _summarize_project(meta),
        "created_clips": created,
        "skipped": skipped,
    }), 201


@bp.post("/api/integrations/prodpod/import-track")
def import_track_from_prodpod():
    """
    Receive one recording track uploaded server-to-server by prodPod. Creates
    the target postPod project if it doesn't exist yet, stores the file in the
    project's media folder, and generates thumbnail/peaks sidecars so the
    editor can use it immediately.

    multipart/form-data fields:
        file               (required) the media blob
        shared_project_id  (required) link to the prePod/prodPod episode
        original_name      (optional) human-readable original filename
        track_type         (optional) video | audio | soundboard
        duration_seconds   (optional) best-effort hint
        participant_name   (optional) who recorded it, for display
        project_name       (optional) used only when auto-creating a project
    """
    err = _require_shared_secret()
    if err:
        return err

    spid = (request.form.get("shared_project_id") or "").strip()
    if not spid:
        return jsonify({"error": "shared_project_id requerido"}), 400

    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido en 'file'"}), 400

    original_name = (request.form.get("original_name") or f.filename).strip()
    incoming_ext = Path(original_name).suffix.lower() or Path(f.filename).suffix.lower()
    file_type = ext_to_type(incoming_ext)
    if not file_type:
        return jsonify({
            "error": f"extensión no soportada: {incoming_ext}",
            "allowed": {k: sorted(v) for k, v in ALLOWED_EXTS.items()},
        }), 400

    # Find or create the project
    meta = find_project_by_shared_id(spid)
    if not meta:
        project_name = (request.form.get("project_name") or "").strip() or f"Episodio {spid[:8]}"
        meta = _create_project_internal(
            name=project_name,
            shared_project_id=spid,
            source_info={
                "app": "prodpod",
                "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "auto_created_by": "prodpod_track_import",
            },
        )
    slug = meta["slug"]

    # Save under the project's media folder
    filename = f"{uuid.uuid4().hex}{incoming_ext}"
    dest_dir = PROJECTS_DIR / slug / "media" / file_type
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / filename
    f.save(str(dest))

    size_bytes = dest.stat().st_size

    # Duration: prefer uploader's hint when ffprobe can't read webm properly
    probed = _probe_duration(dest) if file_type in ("video", "audio") else None
    try:
        hinted = float(request.form.get("duration_seconds") or 0) or None
    except ValueError:
        hinted = None
    duration = probed or hinted

    thumbnail_url = None
    if file_type == "video":
        if _generate_thumbnail(dest, duration):
            from files import _project_thumb_url
            thumbnail_url = _project_thumb_url(slug, file_type, filename)

    peaks_url = None
    if file_type in ("video", "audio"):
        if _generate_waveform(dest, duration):
            from files import _project_peaks_url
            peaks_url = _project_peaks_url(slug, file_type, filename)

    # --- Special handling for prodPod track types ---
    track_type = (request.form.get("track_type") or "").strip().lower()

    # Soundboards arrive as webm but conceptually are audio — convert + route
    # to the audio lane at tl_start=0 (recorded from session start).
    if track_type == "soundboard":
        lane_info = _import_soundboard_to_lane(
            slug, dest, hinted or 0.0, original_name
        )
        if "error" in lane_info:
            return jsonify(lane_info), 500
        return jsonify({
            "project": _summarize_project(meta),
            "file": lane_info,
        }), 201

    # Register video/audio in the project's media db
    db = get_db(slug)
    try:
        cur = db.execute(
            "INSERT INTO media_files (filename, original_name, file_type, duration, size_bytes) "
            "VALUES (?, ?, ?, ?, ?)",
            (filename, original_name, file_type, duration, size_bytes),
        )
        db.commit()
        file_id = cur.lastrowid
    finally:
        db.close()

    # After a participant video arrives, (re)build the hstack composite if
    # we now have 2+ source videos. Best-effort — errors don't fail the upload.
    composite_info = None
    if track_type == "video":
        try:
            composite_info = _compose_hstack_side_by_side(slug)
        except Exception as e:
            composite_info = {"error": f"compose skipped: {e}"}

    return jsonify({
        "project": _summarize_project(meta),
        "file": {
            "id": file_id,
            "filename": filename,
            "original_name": original_name,
            "file_type": file_type,
            "duration": duration,
            "size_bytes": size_bytes,
            "url": _project_file_url(slug, file_type, filename),
            "thumbnail_url": thumbnail_url,
            "peaks_url": peaks_url,
        },
        "composite": composite_info,
    }), 201
