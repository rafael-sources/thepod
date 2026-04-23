"""
REST endpoints for the non-destructive editor: timeline clips, moments,
and operations. Mutations to clips trigger a recalc of relative moments.
"""

import json
import re
import subprocess

from flask import Blueprint, abort, jsonify, request

from auth import require_auth
from config import PROJECTS_DIR
from db import get_db
from timeline import recalc_relative_moments


bp = Blueprint("timeline_api", __name__)


VALID_OP_TYPES = {
    "cut_before", "cut_after", "insert_clip", "switch_video",
    "zoom_in", "zoom_out", "color_effect", "audio_replace",
    "audio_mix", "subtitle", "to_vertical", "remove_silences",
    "jump_to_moment", "switch_track",
}
ABSOLUTE_ALLOWED = {"zoom_in", "zoom_out", "color_effect", "subtitle", "to_vertical",
                    "jump_to_moment", "switch_track"}


def _ensure_project(slug):
    if not (PROJECTS_DIR / slug).exists():
        abort(404, description="proyecto no encontrado")


def _clip_duration(start_offset, end_offset, media_duration):
    start = start_offset or 0.0
    end = end_offset if end_offset is not None else media_duration
    if end is None:
        return 0.0
    return max(0.0, end - start)


def _project_file_url(slug, file_type, filename):
    return f"/media/projects/{slug}/{file_type}/{filename}"


def _global_file_url(file_type, filename):
    return f"/media/global/{file_type}/{filename}"


def _load_clip_list_for_recalc(db):
    """Return list of {id, duration} in timeline order for recalc function."""
    rows = db.execute("""
        SELECT tc.id, tc.start_offset, tc.end_offset, mf.duration AS media_duration
        FROM timeline_clips tc
        LEFT JOIN media_files mf ON mf.id = tc.media_file_id
        ORDER BY tc.position, tc.id
    """).fetchall()
    return [
        {"id": r["id"], "duration": _clip_duration(r["start_offset"], r["end_offset"], r["media_duration"])}
        for r in rows
    ]


def _load_moments(db):
    rows = db.execute("SELECT id, type, timeline_seconds, label FROM moments").fetchall()
    return [dict(r) for r in rows]


def _has_audio_stream(path):
    """Return True if the media file has at least one audio stream."""
    try:
        proc = subprocess.run(
            [
                "ffprobe", "-v", "error", "-select_streams", "a",
                "-show_entries", "stream=codec_type",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            capture_output=True, text=True, timeout=30,
        )
        return "audio" in (proc.stdout or "")
    except (subprocess.SubprocessError, OSError):
        return False


def _apply_moment_updates(db, updates):
    for u in updates:
        db.execute(
            "UPDATE moments SET timeline_seconds=? WHERE id=?",
            (u["timeline_seconds"], u["id"]),
        )


def _normalize_positions(db):
    """Renumber positions to 0..N-1 in the current order. Call after delete/insert/reorder."""
    rows = db.execute("SELECT id FROM timeline_clips ORDER BY position, id").fetchall()
    for i, r in enumerate(rows):
        db.execute("UPDATE timeline_clips SET position=? WHERE id=?", (i, r["id"]))


def snapshot_clips_and_moments(db):
    """Snapshot current clips (for recalc) and moments. Used before external mutations."""
    return _load_clip_list_for_recalc(db), _load_moments(db)


def _silencedetect(path, threshold_db, min_silence):
    """Returns list of (start, end) silence ranges in source-file seconds. Empty on failure."""
    try:
        proc = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-nostats",
                "-i", str(path),
                "-af", f"silencedetect=noise={threshold_db}dB:d={min_silence}",
                "-f", "null", "-",
            ],
            capture_output=True, text=True, timeout=300,
        )
    except subprocess.SubprocessError:
        return []
    starts = [float(m.group(1)) for m in re.finditer(r"silence_start:\s*([\d.]+)", proc.stderr)]
    ends   = [float(m.group(1)) for m in re.finditer(r"silence_end:\s*([\d.]+)",   proc.stderr)]
    return list(zip(starts, ends))


def _remove_silences_in_timeline_range(db, slug, tl_start, tl_end, threshold_db, min_silence):
    """
    Analyze and split clips inside the timeline range [tl_start, tl_end] so that
    silences within that range are removed. Clips outside the range are
    untouched. Returns a summary dict.
    """
    rows = db.execute("""
        SELECT tc.id, tc.position, tc.label, tc.start_offset, tc.end_offset,
               tc.media_file_id,
               mf.filename, mf.file_type, mf.duration AS media_duration
        FROM timeline_clips tc
        LEFT JOIN media_files mf ON mf.id = tc.media_file_id
        ORDER BY tc.position, tc.id
    """).fetchall()

    # Compute cumulative starts in the timeline
    enriched = []
    cursor = 0.0
    for r in rows:
        dur = _clip_duration(r["start_offset"], r["end_offset"], r["media_duration"])
        enriched.append({
            "id": r["id"], "position": r["position"], "media_file_id": r["media_file_id"],
            "label": r["label"], "start_offset": r["start_offset"] or 0.0,
            "end_offset": r["end_offset"], "media_duration": r["media_duration"],
            "filename": r["filename"], "file_type": r["file_type"],
            "tl_start": cursor, "tl_end": cursor + dur, "duration": dur,
        })
        cursor += dur

    affected = [c for c in enriched if c["tl_end"] > tl_start and c["tl_start"] < tl_end]
    if not affected:
        return {"silences_detected": 0, "removed_seconds": 0.0, "splits": 0,
                "skipped_no_audio": 0, "out_of_range": True}

    old_clips_snap, old_moments_snap = snapshot_clips_and_moments(db)

    total_silences = 0
    total_removed = 0.0
    total_splits = 0
    skipped_no_audio = 0

    # Process in reverse original-position order so earlier mutations don't
    # invalidate positions of clips we still need to process.
    for clip in sorted(affected, key=lambda c: -c["position"]):
        fpath = PROJECTS_DIR / slug / "media" / clip["file_type"] / clip["filename"]
        if not fpath.exists() or not _has_audio_stream(fpath):
            skipped_no_audio += 1
            continue

        src_start = clip["start_offset"]
        src_end = clip["end_offset"] if clip["end_offset"] is not None else clip["media_duration"]

        overlap_start_tl = max(tl_start, clip["tl_start"])
        overlap_end_tl = min(tl_end, clip["tl_end"])
        src_overlap_start = src_start + (overlap_start_tl - clip["tl_start"])
        src_overlap_end   = src_start + (overlap_end_tl   - clip["tl_start"])

        raw = _silencedetect(fpath, threshold_db, min_silence)
        silences = []
        for s, e in raw:
            ss, ee = max(s, src_overlap_start), min(e, src_overlap_end)
            if ee - ss > 0.01:
                silences.append((ss, ee))
        if not silences:
            continue

        # Build replacement segments: [start, overlap_start] + kept-in-overlap + [overlap_end, end]
        segs = []
        if src_overlap_start - src_start > 0.02:
            segs.append((src_start, src_overlap_start))
        cur = src_overlap_start
        for s, e in silences:
            if s > cur + 0.02:
                segs.append((cur, s))
            cur = max(cur, e)
        if cur < src_overlap_end - 0.02:
            segs.append((cur, src_overlap_end))
        if src_end - src_overlap_end > 0.02:
            segs.append((src_overlap_end, src_end))

        # Look up current position (may have shifted from earlier iterations)
        current = db.execute(
            "SELECT position FROM timeline_clips WHERE id=?", (clip["id"],)
        ).fetchone()
        if not current:
            continue
        orig_pos = current["position"]
        orig_label = clip["label"] or "clip"
        orig_mfid = clip["media_file_id"]

        db.execute("DELETE FROM timeline_clips WHERE id=?", (clip["id"],))
        _normalize_positions(db)
        n_new = len(segs)
        if n_new > 0:
            db.execute(
                "UPDATE timeline_clips SET position=position+? WHERE position>=?",
                (n_new, orig_pos),
            )
            for i, (s, e) in enumerate(segs):
                db.execute(
                    "INSERT INTO timeline_clips (position, media_file_id, label, start_offset, end_offset) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (orig_pos + i, orig_mfid, f"{orig_label} · {i+1}", s, e),
                )
            _normalize_positions(db)

        total_silences += len(silences)
        total_removed += sum(e - s for s, e in silences)
        total_splits += n_new

    recalc_after_external_change(db, old_clips_snap, old_moments_snap)

    return {
        "silences_detected": total_silences,
        "removed_seconds": round(total_removed, 2),
        "splits": total_splits,
        "skipped_no_audio": skipped_no_audio,
    }


def recalc_after_external_change(db, old_clips, old_moments):
    """
    Call after an external mutation that may have removed/changed timeline_clips
    (for example, deleting a media_file with ON DELETE CASCADE). Renormalizes
    positions and recalculates relative moments.
    """
    _normalize_positions(db)
    new_clips = _load_clip_list_for_recalc(db)
    updates = recalc_relative_moments(old_moments, old_clips, new_clips)
    _apply_moment_updates(db, updates)


def _serialize_clip(slug, row):
    src = None
    if row["filename"]:
        thumb_url = None
        thumb_end_url = None
        peaks_url = None
        media_dir = PROJECTS_DIR / slug / "media" / row["file_type"]
        if row["file_type"] == "video":
            if (media_dir / f"{row['filename']}.thumb.jpg").is_file():
                thumb_url = f"/media/projects/{slug}/{row['file_type']}/{row['filename']}.thumb.jpg"
            if (media_dir / f"{row['filename']}.thumb_end.jpg").is_file():
                thumb_end_url = f"/media/projects/{slug}/{row['file_type']}/{row['filename']}.thumb_end.jpg"
        if row["file_type"] in ("video", "audio"):
            if (media_dir / f"{row['filename']}.peaks.json").is_file():
                peaks_url = f"/media/projects/{slug}/{row['file_type']}/{row['filename']}.peaks.json"
        src = {
            "id": row["media_file_id"],
            "filename": row["filename"],
            "original_name": row["original_name"],
            "file_type": row["file_type"],
            "duration": row["media_duration"],
            "url": _project_file_url(slug, row["file_type"], row["filename"]),
            "thumbnail_url": thumb_url,
            "thumbnail_end_url": thumb_end_url,
            "peaks_url": peaks_url,
        }
    d = {
        "id": row["id"],
        "position": row["position"],
        "media_file_id": row["media_file_id"],
        "label": row["label"],
        "start_offset": row["start_offset"] or 0.0,
        "end_offset": row["end_offset"],
        "duration": _clip_duration(row["start_offset"], row["end_offset"], row["media_duration"]),
        "source": src,
    }
    try: d["track"] = int(row["track"] or 1)
    except (KeyError, IndexError, TypeError): d["track"] = 1
    try: d["volume"] = float(row["volume"] if row["volume"] is not None else 1.0)
    except (KeyError, IndexError, TypeError): d["volume"] = 1.0
    return d


def _load_clips(slug, db):
    rows = db.execute("""
        SELECT tc.id, tc.position, tc.media_file_id, tc.label,
               tc.start_offset, tc.end_offset, tc.track, tc.volume,
               mf.filename, mf.original_name, mf.file_type,
               mf.duration AS media_duration
        FROM timeline_clips tc
        LEFT JOIN media_files mf ON mf.id = tc.media_file_id
        ORDER BY tc.position, tc.id
    """).fetchall()
    return [_serialize_clip(slug, r) for r in rows]


def _load_ops_by_moment(db):
    rows = db.execute("SELECT id, moment_id, type, params FROM operations ORDER BY id").fetchall()
    by_moment = {}
    for r in rows:
        try:
            params = json.loads(r["params"])
        except (ValueError, TypeError):
            params = {}
        by_moment.setdefault(r["moment_id"], []).append({
            "id": r["id"],
            "moment_id": r["moment_id"],
            "type": r["type"],
            "params": params,
        })
    return by_moment


# ---------------------------------------------------------------------------
# GET full timeline
# ---------------------------------------------------------------------------

@bp.get("/api/projects/<slug>/timeline")
@require_auth
def get_timeline(slug):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        clips = _load_clips(slug, db)
        ops_by_moment = _load_ops_by_moment(db)
        moments_rows = db.execute(
            "SELECT id, type, timeline_seconds, label FROM moments ORDER BY timeline_seconds"
        ).fetchall()
        moments = []
        for r in moments_rows:
            moments.append({
                "id": r["id"],
                "type": r["type"],
                "timeline_seconds": r["timeline_seconds"],
                "label": r["label"] or "",
                "operations": ops_by_moment.get(r["id"], []),
            })
        total = sum(c["duration"] for c in clips)
        lane = _load_audio_lane(slug, db)
        return jsonify({
            "clips": clips,
            "moments": moments,
            "duration": total,
            "audio_lane": lane,
        })
    finally:
        db.close()


def _serialize_lane_clip(slug, row):
    src = None
    if row["filename"]:
        media_dir = PROJECTS_DIR / slug / "media" / "audio"
        peaks_url = None
        if (media_dir / f"{row['filename']}.peaks.json").is_file():
            peaks_url = f"/media/projects/{slug}/audio/{row['filename']}.peaks.json"
        src = {
            "id": row["media_file_id"],
            "filename": row["filename"],
            "original_name": row["original_name"],
            "duration": row["media_duration"],
            "url": _project_file_url(slug, "audio", row["filename"]),
            "peaks_url": peaks_url,
        }
    end_offset = row["end_offset"] if row["end_offset"] is not None else row["media_duration"]
    dur = max(0.0, float(end_offset or 0) - float(row["start_offset"] or 0))
    return {
        "id": row["id"],
        "media_file_id": row["media_file_id"],
        "label": row["label"] or (row["original_name"] if row["filename"] else ""),
        "tl_start": float(row["tl_start"] or 0),
        "tl_end": float(row["tl_start"] or 0) + dur,
        "start_offset": float(row["start_offset"] or 0),
        "end_offset": float(end_offset) if end_offset is not None else None,
        "duration": dur,
        "volume": float(row["volume"] or 0.7),
        "source": src,
    }


def _load_audio_lane(slug, db):
    rows = db.execute("""
        SELECT al.id, al.media_file_id, al.label, al.tl_start,
               al.start_offset, al.end_offset, al.volume,
               mf.filename, mf.original_name,
               mf.duration AS media_duration
        FROM audio_lane_clips al
        LEFT JOIN media_files mf ON mf.id = al.media_file_id
        ORDER BY al.tl_start, al.id
    """).fetchall()
    return [_serialize_lane_clip(slug, r) for r in rows]


# ---------------------------------------------------------------------------
# Audio lane CRUD
# ---------------------------------------------------------------------------

@bp.post("/api/projects/<slug>/audio-lane")
@require_auth
def add_lane_clip(slug):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    mfid = data.get("media_file_id")
    if mfid is None:
        return jsonify({"error": "media_file_id requerido"}), 400
    db = get_db(slug)
    try:
        mf = db.execute(
            "SELECT id, file_type, duration FROM media_files WHERE id=?", (mfid,),
        ).fetchone()
        if not mf:
            return jsonify({"error": "media_file no encontrado"}), 404
        if mf["file_type"] != "audio":
            return jsonify({"error": "sólo archivos de audio en la pista de audio"}), 400

        tl_start = float(data.get("tl_start") or 0)
        start_offset = float(data.get("start_offset") or 0)
        end_offset = data.get("end_offset")
        if end_offset is not None:
            end_offset = float(end_offset)
        volume = float(data.get("volume", 0.7))
        volume = max(0.0, min(2.0, volume))

        cur = db.execute(
            """INSERT INTO audio_lane_clips
               (media_file_id, label, tl_start, start_offset, end_offset, volume)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (mfid, data.get("label"), tl_start, start_offset, end_offset, volume),
        )
        db.commit()
        row = db.execute("""
            SELECT al.id, al.media_file_id, al.label, al.tl_start,
                   al.start_offset, al.end_offset, al.volume,
                   mf.filename, mf.original_name, mf.duration AS media_duration
            FROM audio_lane_clips al
            LEFT JOIN media_files mf ON mf.id = al.media_file_id
            WHERE al.id = ?
        """, (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_lane_clip(slug, row)), 201
    finally:
        db.close()


@bp.put("/api/projects/<slug>/audio-lane/<int:clip_id>")
@require_auth
def update_lane_clip(slug, clip_id):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM audio_lane_clips WHERE id=?", (clip_id,)).fetchone()
        if not row:
            return jsonify({"error": "clip no encontrado"}), 404
        updates, params = [], []
        for field in ("label",):
            if field in data:
                updates.append(f"{field}=?")
                params.append(data[field])
        for field in ("tl_start", "start_offset", "volume"):
            if field in data:
                updates.append(f"{field}=?")
                params.append(float(data[field] or 0))
        if "end_offset" in data:
            val = data["end_offset"]
            updates.append("end_offset=?")
            params.append(float(val) if val is not None else None)
        if updates:
            params.append(clip_id)
            db.execute(f"UPDATE audio_lane_clips SET {', '.join(updates)} WHERE id=?", params)
            db.commit()
        row = db.execute("""
            SELECT al.id, al.media_file_id, al.label, al.tl_start,
                   al.start_offset, al.end_offset, al.volume,
                   mf.filename, mf.original_name, mf.duration AS media_duration
            FROM audio_lane_clips al
            LEFT JOIN media_files mf ON mf.id = al.media_file_id
            WHERE al.id = ?
        """, (clip_id,)).fetchone()
        return jsonify(_serialize_lane_clip(slug, row))
    finally:
        db.close()


@bp.delete("/api/projects/<slug>/audio-lane/<int:clip_id>")
@require_auth
def delete_lane_clip(slug, clip_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        db.execute("DELETE FROM audio_lane_clips WHERE id=?", (clip_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Clips
# ---------------------------------------------------------------------------

@bp.post("/api/projects/<slug>/timeline/clips")
@require_auth
def add_clip(slug):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    mfid = data.get("media_file_id")
    if mfid is None:
        return jsonify({"error": "media_file_id requerido"}), 400

    db = get_db(slug)
    try:
        mf = db.execute(
            "SELECT id, duration FROM media_files WHERE id=?", (mfid,),
        ).fetchone()
        if not mf:
            return jsonify({"error": "media_file no encontrado"}), 404

        count = db.execute("SELECT COUNT(*) AS n FROM timeline_clips").fetchone()["n"]
        position = data.get("position")
        if position is None or position > count:
            position = count
        position = max(0, int(position))

        start_offset = float(data.get("start_offset", 0) or 0)
        end_offset = data.get("end_offset")
        if end_offset is not None:
            end_offset = float(end_offset)
        track = int(data.get("track") or 1)
        if track not in (1, 2):
            track = 1

        old_clips = _load_clip_list_for_recalc(db)
        moments = _load_moments(db)

        # Bump positions at/after insertion point
        db.execute(
            "UPDATE timeline_clips SET position = position + 1 WHERE position >= ?",
            (position,),
        )
        cur = db.execute(
            "INSERT INTO timeline_clips (position, media_file_id, label, start_offset, end_offset, track) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (position, mfid, data.get("label"), start_offset, end_offset, track),
        )
        new_id = cur.lastrowid
        _normalize_positions(db)

        new_clips = _load_clip_list_for_recalc(db)
        updates = recalc_relative_moments(moments, old_clips, new_clips)
        _apply_moment_updates(db, updates)
        db.commit()

        clip_row = db.execute("""
            SELECT tc.id, tc.position, tc.media_file_id, tc.label,
                   tc.start_offset, tc.end_offset, tc.track, tc.volume,
                   mf.filename, mf.original_name, mf.file_type,
                   mf.duration AS media_duration
            FROM timeline_clips tc
            LEFT JOIN media_files mf ON mf.id = tc.media_file_id
            WHERE tc.id = ?
        """, (new_id,)).fetchone()
        return jsonify(_serialize_clip(slug, clip_row)), 201
    finally:
        db.close()


@bp.put("/api/projects/<slug>/timeline/clips/<int:clip_id>")
@require_auth
def update_clip(slug, clip_id):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT id, position, start_offset, end_offset FROM timeline_clips WHERE id=?",
            (clip_id,),
        ).fetchone()
        if not row:
            return jsonify({"error": "clip no encontrado"}), 404

        old_clips = _load_clip_list_for_recalc(db)
        moments = _load_moments(db)

        # Trivial fields
        updates_sql = []
        params = []
        for field in ("label",):
            if field in data:
                updates_sql.append(f"{field}=?")
                params.append(data[field])
        if "start_offset" in data:
            updates_sql.append("start_offset=?")
            params.append(float(data["start_offset"] or 0))
        if "end_offset" in data:
            val = data["end_offset"]
            updates_sql.append("end_offset=?")
            params.append(float(val) if val is not None else None)
        if "track" in data:
            t = int(data["track"] or 1)
            if t not in (1, 2):
                return jsonify({"error": "track debe ser 1 o 2"}), 400
            updates_sql.append("track=?")
            params.append(t)
        if "volume" in data:
            v = float(data["volume"] or 0)
            v = max(0.0, min(4.0, v))
            updates_sql.append("volume=?")
            params.append(v)

        if updates_sql:
            params.append(clip_id)
            db.execute(
                f"UPDATE timeline_clips SET {', '.join(updates_sql)} WHERE id=?",
                params,
            )

        # Reorder if position provided
        if "position" in data and data["position"] is not None:
            old_pos = row["position"]
            new_pos = max(0, int(data["position"]))
            count = db.execute("SELECT COUNT(*) AS n FROM timeline_clips").fetchone()["n"]
            new_pos = min(new_pos, count - 1)
            if new_pos != old_pos:
                # Park target out of range to avoid intermediate collisions
                db.execute("UPDATE timeline_clips SET position=-1 WHERE id=?", (clip_id,))
                if new_pos > old_pos:
                    db.execute(
                        "UPDATE timeline_clips SET position=position-1 "
                        "WHERE position > ? AND position <= ?",
                        (old_pos, new_pos),
                    )
                else:
                    db.execute(
                        "UPDATE timeline_clips SET position=position+1 "
                        "WHERE position >= ? AND position < ?",
                        (new_pos, old_pos),
                    )
                db.execute("UPDATE timeline_clips SET position=? WHERE id=?", (new_pos, clip_id))
            _normalize_positions(db)

        new_clips = _load_clip_list_for_recalc(db)
        moment_updates = recalc_relative_moments(moments, old_clips, new_clips)
        _apply_moment_updates(db, moment_updates)
        db.commit()

        updated = db.execute("""
            SELECT tc.id, tc.position, tc.media_file_id, tc.label,
                   tc.start_offset, tc.end_offset, tc.track, tc.volume,
                   mf.filename, mf.original_name, mf.file_type,
                   mf.duration AS media_duration
            FROM timeline_clips tc
            LEFT JOIN media_files mf ON mf.id = tc.media_file_id
            WHERE tc.id = ?
        """, (clip_id,)).fetchone()
        return jsonify(_serialize_clip(slug, updated))
    finally:
        db.close()


@bp.delete("/api/projects/<slug>/timeline/clips/<int:clip_id>")
@require_auth
def delete_clip(slug, clip_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM timeline_clips WHERE id=?", (clip_id,)).fetchone()
        if not row:
            return jsonify({"error": "clip no encontrado"}), 404

        old_clips = _load_clip_list_for_recalc(db)
        moments = _load_moments(db)

        db.execute("DELETE FROM timeline_clips WHERE id=?", (clip_id,))
        _normalize_positions(db)

        new_clips = _load_clip_list_for_recalc(db)
        updates = recalc_relative_moments(moments, old_clips, new_clips)
        _apply_moment_updates(db, updates)
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Moments
# ---------------------------------------------------------------------------

@bp.post("/api/projects/<slug>/moments")
@require_auth
def create_moment(slug):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    mtype = data.get("type")
    if mtype not in ("relative", "absolute"):
        return jsonify({"error": "type debe ser 'relative' o 'absolute'"}), 400
    t = data.get("timeline_seconds")
    if t is None:
        return jsonify({"error": "timeline_seconds requerido"}), 400

    db = get_db(slug)
    try:
        cur = db.execute(
            "INSERT INTO moments (type, timeline_seconds, label) VALUES (?, ?, ?)",
            (mtype, float(t), data.get("label") or ""),
        )
        db.commit()
        return jsonify({
            "id": cur.lastrowid,
            "type": mtype,
            "timeline_seconds": float(t),
            "label": data.get("label") or "",
            "operations": [],
        }), 201
    finally:
        db.close()


@bp.put("/api/projects/<slug>/moments/<int:moment_id>")
@require_auth
def update_moment(slug, moment_id):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM moments WHERE id=?", (moment_id,)).fetchone()
        if not row:
            return jsonify({"error": "momento no encontrado"}), 404
        updates_sql, params = [], []
        if "label" in data:
            updates_sql.append("label=?")
            params.append(data["label"] or "")
        if "timeline_seconds" in data:
            updates_sql.append("timeline_seconds=?")
            params.append(float(data["timeline_seconds"]))
        if "type" in data:
            t = data["type"]
            if t not in ("relative", "absolute"):
                return jsonify({"error": "type debe ser 'relative' o 'absolute'"}), 400
            updates_sql.append("type=?")
            params.append(t)
        if updates_sql:
            params.append(moment_id)
            db.execute(
                f"UPDATE moments SET {', '.join(updates_sql)} WHERE id=?",
                params,
            )
            db.commit()
        updated = db.execute(
            "SELECT id, type, timeline_seconds, label FROM moments WHERE id=?",
            (moment_id,),
        ).fetchone()
        return jsonify({
            **dict(updated),
            "label": updated["label"] or "",
        })
    finally:
        db.close()


@bp.delete("/api/projects/<slug>/moments/<int:moment_id>")
@require_auth
def delete_moment(slug, moment_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM moments WHERE id=?", (moment_id,)).fetchone()
        if not row:
            return jsonify({"error": "momento no encontrado"}), 404
        db.execute("DELETE FROM moments WHERE id=?", (moment_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

@bp.get("/api/projects/<slug>/moments/<int:moment_id>/operations")
@require_auth
def list_operations(slug, moment_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT id, moment_id, type, params FROM operations WHERE moment_id=? ORDER BY id",
            (moment_id,),
        ).fetchall()
        out = []
        for r in rows:
            try:
                params = json.loads(r["params"])
            except (ValueError, TypeError):
                params = {}
            out.append({"id": r["id"], "moment_id": r["moment_id"], "type": r["type"], "params": params})
        return jsonify(out)
    finally:
        db.close()


@bp.post("/api/projects/<slug>/moments/<int:moment_id>/operations")
@require_auth
def create_operation(slug, moment_id):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    op_type = data.get("type")
    if op_type not in VALID_OP_TYPES:
        return jsonify({"error": f"tipo de operación inválido: {op_type}"}), 400
    params = data.get("params") or {}
    if not isinstance(params, dict):
        return jsonify({"error": "params debe ser un objeto"}), 400

    db = get_db(slug)
    try:
        moment = db.execute(
            "SELECT id, type, timeline_seconds FROM moments WHERE id=?", (moment_id,)
        ).fetchone()
        if not moment:
            return jsonify({"error": "momento no encontrado"}), 404
        if moment["type"] == "absolute" and op_type not in ABSOLUTE_ALLOWED:
            return jsonify({
                "error": f"los momentos absolutos sólo aceptan: {sorted(ABSOLUTE_ALLOWED)}"
            }), 400

        # remove_silences is applied immediately to the timeline (splits clips in range).
        silence_result = None
        if op_type == "remove_silences":
            try:
                threshold_db = float(params.get("threshold_db", -40))
                min_silence = float(params.get("min_silence_seconds", 0.5))
                duration = float(params.get("duration_seconds") or 0)
            except (TypeError, ValueError):
                return jsonify({"error": "parámetros inválidos para remove_silences"}), 400
            if duration <= 0:
                return jsonify({
                    "error": "remove_silences requiere duration_seconds > 0"
                }), 400
            tl_start = float(moment["timeline_seconds"])
            tl_end = tl_start + duration
            silence_result = _remove_silences_in_timeline_range(
                db, slug, tl_start, tl_end, threshold_db, min_silence,
            )

        cur = db.execute(
            "INSERT INTO operations (moment_id, type, params) VALUES (?, ?, ?)",
            (moment_id, op_type, json.dumps(params)),
        )
        db.commit()
        resp = {
            "id": cur.lastrowid,
            "moment_id": moment_id,
            "type": op_type,
            "params": params,
        }
        if silence_result is not None:
            resp["silence_result"] = silence_result
        return jsonify(resp), 201
    finally:
        db.close()


@bp.post("/api/projects/<slug>/timeline/clips/<int:clip_id>/remove-silences")
@require_auth
def remove_silences_from_clip(slug, clip_id):
    _ensure_project(slug)
    data = request.get_json(silent=True) or {}
    try:
        threshold_db = float(data.get("threshold_db", -40))
        min_silence = float(data.get("min_silence_seconds", 0.5))
    except (TypeError, ValueError):
        return jsonify({"error": "parámetros inválidos"}), 400

    db = get_db(slug)
    try:
        clip = db.execute("""
            SELECT tc.id, tc.position, tc.label, tc.start_offset, tc.end_offset,
                   tc.media_file_id,
                   mf.filename, mf.file_type, mf.duration AS media_duration
            FROM timeline_clips tc
            LEFT JOIN media_files mf ON mf.id = tc.media_file_id
            WHERE tc.id = ?
        """, (clip_id,)).fetchone()
        if not clip or not clip["filename"]:
            return jsonify({"error": "clip no encontrado o archivo ausente"}), 404

        fpath = PROJECTS_DIR / slug / "media" / clip["file_type"] / clip["filename"]
        if not fpath.exists():
            return jsonify({"error": "archivo fuente no existe en disco"}), 410

        if not _has_audio_stream(fpath):
            return jsonify({
                "error": "este archivo no tiene pista de audio — no se pueden detectar silencios"
            }), 400

        try:
            proc = subprocess.run(
                [
                    "ffmpeg", "-hide_banner", "-nostats",
                    "-i", str(fpath),
                    "-af", f"silencedetect=noise={threshold_db}dB:d={min_silence}",
                    "-f", "null", "-",
                ],
                capture_output=True, text=True, timeout=300,
            )
        except subprocess.TimeoutExpired:
            return jsonify({"error": "análisis tomó demasiado tiempo"}), 504

        starts = [float(m.group(1)) for m in re.finditer(r"silence_start:\s*([\d.]+)", proc.stderr)]
        ends   = [float(m.group(1)) for m in re.finditer(r"silence_end:\s*([\d.]+)",   proc.stderr)]
        raw_silences = list(zip(starts, ends))

        src_start = float(clip["start_offset"] or 0)
        media_dur = float(clip["media_duration"] or 0)
        src_end = float(clip["end_offset"]) if clip["end_offset"] is not None else media_dur

        # Clamp silences to the clip's source range
        silences = []
        for s, e in raw_silences:
            s_c, e_c = max(s, src_start), min(e, src_end)
            if e_c - s_c > 0.01:
                silences.append((s_c, e_c))

        if not silences:
            return jsonify({"ok": True, "splits": 0, "removed_seconds": 0.0,
                            "message": "no se detectaron silencios en este clip"})

        # Build non-silent segments
        segments = []
        cursor = src_start
        for s, e in silences:
            if s > cursor + 0.02:
                segments.append((cursor, s))
            cursor = max(cursor, e)
        if cursor < src_end - 0.02:
            segments.append((cursor, src_end))

        if len(segments) <= 1 and not silences:
            return jsonify({"ok": True, "splits": 0, "removed_seconds": 0.0,
                            "message": "sin cambios"})

        # Snapshot before mutation (for moment recalc)
        old_clips, old_moments = snapshot_clips_and_moments(db)

        orig_pos = clip["position"]
        orig_label = clip["label"] or ""
        orig_mfid = clip["media_file_id"]

        # Remove original, normalize, then insert new segments at orig_pos
        db.execute("DELETE FROM timeline_clips WHERE id=?", (clip_id,))
        _normalize_positions(db)

        n_new = len(segments)
        if n_new > 0:
            db.execute(
                "UPDATE timeline_clips SET position=position+? WHERE position>=?",
                (n_new, orig_pos),
            )
            base = orig_label if orig_label else "clip"
            for i, (s, e) in enumerate(segments):
                db.execute(
                    "INSERT INTO timeline_clips (position, media_file_id, label, start_offset, end_offset) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (orig_pos + i, orig_mfid, f"{base} · {i+1}", s, e),
                )
            _normalize_positions(db)

        recalc_after_external_change(db, old_clips, old_moments)
        db.commit()

        removed = sum(e - s for s, e in silences)
        kept = sum(e - s for s, e in segments)
        return jsonify({
            "ok": True,
            "splits": n_new,
            "silences_detected": len(silences),
            "removed_seconds": round(removed, 2),
            "kept_seconds": round(kept, 2),
        })
    finally:
        db.close()


@bp.delete("/api/projects/<slug>/operations/<int:op_id>")
@require_auth
def delete_operation(slug, op_id):
    _ensure_project(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT id FROM operations WHERE id=?", (op_id,)).fetchone()
        if not row:
            return jsonify({"error": "operación no encontrada"}), 404
        db.execute("DELETE FROM operations WHERE id=?", (op_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()
