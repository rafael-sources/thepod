"""
FFmpeg export pipeline for postPod.

Takes the non-destructive state of a project (timeline_clips + moments +
operations) and produces a single rendered file according to a preset.

- `build_ffmpeg_command(slug, preset, output_path)` assembles the command list.
- `run_export(slug, job_id)` runs it asynchronously in a thread and updates
  the `export_jobs` row with progress and final status.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import threading
import time
from pathlib import Path

from config import PROJECTS_DIR, drawtext_fontfile, find_preset
from db import get_db


# Track running ffmpeg processes so we can cancel them. Key = (slug, job_id).
_ACTIVE_JOBS: dict[tuple, subprocess.Popen] = {}
_ACTIVE_LOCK = threading.Lock()


def cancel_export(slug: str, job_id: int) -> bool:
    """Signal a running export job to stop. Returns True if a process was signaled."""
    key = (slug, int(job_id))
    with _ACTIVE_LOCK:
        proc = _ACTIVE_JOBS.get(key)
    if not proc:
        return False
    try:
        # Kill the whole process group (ffmpeg + any children). setsid in Popen ensures a group.
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.terminate()
        except Exception:
            return False
    return True


# ---------------------------------------------------------------------------
# Clip / op loading
# ---------------------------------------------------------------------------

def _has_audio_stream(path: Path) -> bool:
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


def _clip_duration(start_offset, end_offset, media_duration) -> float:
    start = float(start_offset or 0)
    end = float(end_offset) if end_offset is not None else float(media_duration or 0)
    return max(0.0, end - start)


def _resolve_media_file_path(slug: str, media_file_id: int):
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT filename, file_type FROM media_files WHERE id=?", (media_file_id,),
        ).fetchone()
        if not row:
            return None
        return PROJECTS_DIR / slug / "media" / row["file_type"] / row["filename"]
    finally:
        db.close()


def _load_timeline_state(slug: str):
    """Return (clips_list, flat_ops, all_have_audio, total_duration, moments)."""
    db = get_db(slug)
    try:
        clip_rows = db.execute("""
            SELECT tc.id, tc.position, tc.start_offset, tc.end_offset, tc.track, tc.volume,
                   mf.filename, mf.file_type, mf.duration AS media_duration
            FROM timeline_clips tc
            LEFT JOIN media_files mf ON mf.id = tc.media_file_id
            ORDER BY tc.position, tc.id
        """).fetchall()
        clips = []
        cursor = {1: 0.0, 2: 0.0}  # per-track cumulative start
        for r in clip_rows:
            if not r["filename"]:
                continue
            path = PROJECTS_DIR / slug / "media" / r["file_type"] / r["filename"]
            dur = _clip_duration(r["start_offset"], r["end_offset"], r["media_duration"])
            if dur <= 0:
                continue
            track = int(r["track"] or 1)
            if track not in (1, 2):
                track = 1
            tl_start = cursor[track]
            try:
                clip_vol = float(r["volume"]) if r["volume"] is not None else 1.0
            except (KeyError, IndexError, TypeError):
                clip_vol = 1.0
            clips.append({
                "id": r["id"],
                "path": path,
                "file_type": r["file_type"],
                "track": track,
                "volume": max(0.0, min(4.0, clip_vol)),
                "start_offset": float(r["start_offset"] or 0),
                "end_offset": float(r["end_offset"]) if r["end_offset"] is not None else float(r["media_duration"] or 0),
                "duration": dur,
                "tl_start": tl_start,
                "tl_end": tl_start + dur,
                "has_audio": _has_audio_stream(path),
            })
            cursor[track] = tl_start + dur

        moment_rows = db.execute(
            "SELECT id, type, timeline_seconds, label FROM moments ORDER BY timeline_seconds, id"
        ).fetchall()
        moments = [dict(m) for m in moment_rows]

        op_rows = db.execute(
            "SELECT id, moment_id, type, params FROM operations ORDER BY id"
        ).fetchall()
        ops_by_moment = {}
        for r in op_rows:
            try:
                params = json.loads(r["params"])
            except (ValueError, TypeError):
                params = {}
            ops_by_moment.setdefault(r["moment_id"], []).append({
                "id": r["id"], "type": r["type"], "params": params,
            })

        flat_ops = []
        for m in moments:
            for op in ops_by_moment.get(m["id"], []):
                flat_ops.append({
                    **op,
                    "tl_start": float(m["timeline_seconds"]),
                    "moment_type": m["type"],
                })

        all_have_audio = bool(clips) and all(c["has_audio"] for c in clips)

        lane_rows = db.execute("""
            SELECT al.id, al.tl_start, al.start_offset, al.end_offset, al.volume,
                   mf.filename, mf.file_type, mf.duration AS media_duration
            FROM audio_lane_clips al
            LEFT JOIN media_files mf ON mf.id = al.media_file_id
            ORDER BY al.tl_start, al.id
        """).fetchall()
        audio_lane = []
        for r in lane_rows:
            if not r["filename"]:
                continue
            path = PROJECTS_DIR / slug / "media" / "audio" / r["filename"]
            s = float(r["start_offset"] or 0)
            e = float(r["end_offset"]) if r["end_offset"] is not None else float(r["media_duration"] or 0)
            dur = max(0.0, e - s)
            if dur <= 0:
                continue
            audio_lane.append({
                "id": r["id"],
                "path": path,
                "tl_start": float(r["tl_start"] or 0),
                "tl_end": float(r["tl_start"] or 0) + dur,
                "start_offset": s,
                "end_offset": e,
                "duration": dur,
                "volume": float(r["volume"] or 0.7),
            })

        video_total = max((c["tl_end"] for c in clips), default=0.0)
        lane_total = max((l["tl_end"] for l in audio_lane), default=0.0)
        total = max(video_total, lane_total)
        return clips, flat_ops, all_have_audio, total, moments, audio_lane
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Filter helpers
# ---------------------------------------------------------------------------

def _escape_drawtext(text: str) -> str:
    return (text.replace("\\", "\\\\")
                .replace(":", "\\:")
                .replace("'", "\u2019")
                .replace("%", "\\%"))


def _compute_track_segments(clips, moments, flat_ops, total_duration):
    """
    Walk the timeline from 0 to total_duration, following switch_track ops to
    determine the active track at each instant, and emit a list of segments
    that describe which source clip (and which sub-range of it) should play
    during each [tl_start, tl_end] window. Segments never overlap.
    """
    if not clips:
        return []

    # Boundaries: clip starts/ends on either track + switch_track moments + 0/total
    bounds = {0.0, float(total_duration)}
    for c in clips:
        bounds.add(float(c["tl_start"]))
        bounds.add(float(c["tl_end"]))
    moment_by_id = {m["id"]: m for m in moments}
    sw_events = []
    for op in flat_ops:
        if op["type"] != "switch_track":
            continue
        m = moment_by_id.get(op.get("moment_id")) or None
        t = op.get("tl_start")
        if t is None and m is not None:
            t = float(m["timeline_seconds"])
        if t is None:
            continue
        t = float(t)
        bounds.add(t)
        sw_events.append((t, op.get("params") or {}))
    sw_events.sort(key=lambda x: x[0])

    times = sorted(x for x in bounds if -1e-6 <= x <= total_duration + 1e-6)

    def active_at(t):
        a = 1
        for (st, p) in sw_events:
            if st > t + 1e-6:
                break
            if p.get("toggle"):
                a = 1 if a == 2 else 2
            elif p.get("track") in (1, 2):
                a = int(p["track"])
        return a

    def clip_on_track_at(track, t):
        for c in clips:
            if int(c.get("track", 1)) != track:
                continue
            if c["tl_start"] - 1e-6 <= t < c["tl_end"] - 1e-6:
                return c
        return None

    segments = []
    for i in range(len(times) - 1):
        t0, t1 = times[i], times[i + 1]
        if t1 - t0 < 0.001:
            continue
        at = active_at(t0)
        c = clip_on_track_at(at, t0) or clip_on_track_at(2 if at == 1 else 1, t0)
        if not c:
            continue
        local_start = float(c["start_offset"]) + (t0 - c["tl_start"])
        local_end = float(c["start_offset"]) + (t1 - c["tl_start"])
        segments.append({
            "clip": c,
            "src_start": local_start,
            "src_end": local_end,
            "tl_start": t0,
            "tl_end": t1,
            "duration": t1 - t0,
        })
    return segments


def _compute_final_keep_ranges(flat_ops, moments, total_duration):
    """
    Build the list of (start, end) time ranges in the ORIGINAL timeline that
    should actually reach the final output. Accounts for:
      - jump_to_moment ops: skip [source..target] when target > source;
        backward jumps are ignored in export (would create a loop).
      - cut_before (max tl) and cut_after (min tl): global clamp.

    Returns a list of (start, end) pairs, possibly overlapping-free and sorted.
    """
    moment_time = {m["id"]: float(m["timeline_seconds"]) for m in moments}
    jumps = []
    for op in flat_ops:
        if op["type"] != "jump_to_moment":
            continue
        src = float(op["tl_start"])
        tgt_id = (op.get("params") or {}).get("target_moment_id")
        if tgt_id is None or tgt_id not in moment_time:
            continue
        tgt = float(moment_time[tgt_id])
        if tgt <= src + 0.01:
            continue  # ignore backward/zero jumps
        jumps.append((src, tgt))
    jumps.sort()

    # Build ranges from jumps (forward skip list)
    ranges = []
    cursor = 0.0
    for src, tgt in jumps:
        if src < cursor:
            continue  # already past this jump's source in a skipped window
        if src > cursor + 0.01:
            ranges.append((cursor, src))
        cursor = max(cursor, tgt)
    if cursor < total_duration - 0.01:
        ranges.append((cursor, total_duration))
    if not ranges:
        ranges = [(0.0, total_duration)]

    # Intersect with cut_before / cut_after
    cut_before_Ts = [o["tl_start"] for o in flat_ops if o["type"] == "cut_before"]
    cut_before_T = max(cut_before_Ts) if cut_before_Ts else 0.0
    cut_after_Ts = [o["tl_start"] for o in flat_ops if o["type"] == "cut_after"]
    cut_after_T = min(cut_after_Ts) if cut_after_Ts else total_duration
    cut_before_T = max(0.0, min(cut_before_T, total_duration))
    cut_after_T = max(cut_before_T, min(cut_after_T, total_duration))

    clipped = []
    for s, e in ranges:
        if e <= cut_before_T or s >= cut_after_T:
            continue
        clipped.append((max(s, cut_before_T), min(e, cut_after_T)))
    if not clipped:
        clipped = [(cut_before_T, cut_after_T)]
    return clipped


def _apply_final_ranges(parts, label, ranges, kind, total_duration, out_label):
    """
    Reduce `label` to the concatenation of `ranges`, emitting the result as
    `out_label`. If only one range and it covers everything, simply passes
    through with null/anull to keep the contract of returning `out_label`.
    kind: 'v' for video, 'a' for audio.
    """
    is_video = (kind == "v")
    is_single_full = (
        len(ranges) == 1
        and ranges[0][0] <= 0.01
        and ranges[0][1] >= total_duration - 0.01
    )
    if is_single_full:
        parts.append(f"[{label}]{'null' if is_video else 'anull'}[{out_label}]")
        return out_label

    if len(ranges) == 1:
        s, e = ranges[0]
        trim_f = "trim" if is_video else "atrim"
        pts_f = "setpts=PTS-STARTPTS" if is_video else "asetpts=PTS-STARTPTS"
        parts.append(f"[{label}]{trim_f}=start={s:.3f}:end={e:.3f},{pts_f}[{out_label}]")
        return out_label

    n = len(ranges)
    split_f = "split" if is_video else "asplit"
    trim_f = "trim" if is_video else "atrim"
    pts_f = "setpts=PTS-STARTPTS" if is_video else "asetpts=PTS-STARTPTS"
    split_labels = [f"jmp{kind}s{i}" for i in range(n)]
    parts.append(f"[{label}]{split_f}={n}[" + "][".join(split_labels) + "]")
    out_labels = []
    for i, (s, e) in enumerate(ranges):
        lbl = f"jmp{kind}r{i}"
        parts.append(f"[{split_labels[i]}]{trim_f}=start={s:.3f}:end={e:.3f},{pts_f}[{lbl}]")
        out_labels.append(lbl)
    concat_in = "".join(f"[{x}]" for x in out_labels)
    v_n = 1 if is_video else 0
    a_n = 0 if is_video else 1
    parts.append(f"{concat_in}concat=n={n}:v={v_n}:a={a_n}[{out_label}]")
    return out_label


def _segment_transform(parts, current_label, T, D, total, transform_filter, uid_prefix):
    """
    Apply `transform_filter` to the [T, T+D] segment of `current_label`
    using split/trim/concat. Returns the new label.

    - If the range is empty or covers nothing useful, returns current_label unchanged.
    - If the range covers the whole stream, applies filter directly (no split).
    """
    T = max(0.0, float(T))
    T_end = min(float(T) + float(D), total)
    if T_end <= T + 0.01:
        return current_label

    segments = []
    if T > 0.01:
        segments.append(("before", 0.0, T, None))
    segments.append(("mid", T, T_end, transform_filter))
    if T_end < total - 0.01:
        segments.append(("after", T_end, total, None))

    if len(segments) == 1:
        new_label = f"{uid_prefix}out"
        parts.append(f"[{current_label}]{transform_filter}[{new_label}]")
        return new_label

    n = len(segments)
    split_labels = [f"{uid_prefix}s{i}" for i in range(n)]
    parts.append(f"[{current_label}]split={n}[" + "][".join(split_labels) + "]")

    out_labels = []
    for i, (name, start, end, trans) in enumerate(segments):
        label_out = f"{uid_prefix}{name}"
        chain = f"trim=start={start:.3f}:end={end:.3f},setpts=PTS-STARTPTS"
        if trans:
            chain += f",{trans}"
        parts.append(f"[{split_labels[i]}]{chain}[{label_out}]")
        out_labels.append(label_out)

    concat_name = f"{uid_prefix}out"
    concat_in = "".join(f"[{x}]" for x in out_labels)
    parts.append(f"{concat_in}concat=n={len(out_labels)}:v=1:a=0[{concat_name}]")
    return concat_name


def _apply_video_ops(parts, current_label, flat_ops, total_duration, next_moment_time, W, H):
    """Apply all supported video operations. Returns the new label."""
    fontfile = drawtext_fontfile()
    uid = 0
    ops = sorted(flat_ops, key=lambda o: o["tl_start"])

    for op in ops:
        op_type = op["type"]
        if op_type in ("cut_before", "cut_after",
                       "audio_mix", "audio_replace",
                       "insert_clip", "switch_video",
                       "zoom_out",
                       "remove_silences"):
            continue

        t = op["tl_start"]
        p = op.get("params", {}) or {}
        dur_raw = p.get("duration_seconds")
        dur = float(dur_raw) if dur_raw is not None else float(next_moment_time(t, total_duration))
        if dur <= 0:
            continue
        t_end = min(t + dur, total_duration)

        uid += 1

        if op_type == "color_effect":
            effect = p.get("effect", "grayscale")
            new_label = f"vop{uid}"
            enable = f"between(t,{t:.3f},{t_end:.3f})"
            if effect == "grayscale":
                flt = f"hue=s=0:enable='{enable}'"
            elif effect == "sepia":
                flt = (
                    "colorchannelmixer="
                    ".393:.769:.189:0:"
                    ".349:.686:.168:0:"
                    ".272:.534:.131:0"
                    f":enable='{enable}'"
                )
            elif effect == "invert":
                flt = f"negate=enable='{enable}'"
            else:
                continue
            parts.append(f"[{current_label}]{flt}[{new_label}]")
            current_label = new_label

        elif op_type == "subtitle":
            new_label = f"vop{uid}"
            text = _escape_drawtext(p.get("text") or "")
            position = p.get("position", "bottom")
            y_expr = "60" if position == "top" else "h-120"
            enable = f"between(t,{t:.3f},{t_end:.3f})"
            font_part = f":fontfile='{fontfile}'" if fontfile else ""
            flt = (
                f"drawtext=text='{text}'"
                f"{font_part}"
                f":fontsize=48:fontcolor=white"
                f":box=1:boxcolor=black@0.6:boxborderw=12"
                f":x=(w-tw)/2:y={y_expr}"
                f":enable='{enable}'"
            )
            parts.append(f"[{current_label}]{flt}[{new_label}]")
            current_label = new_label

        elif op_type == "zoom_in":
            try:
                s = float(p.get("scale", 1.5))
            except (TypeError, ValueError):
                s = 1.5
            s = max(1.01, min(4.0, s))
            ox = max(0.0, min(1.0, float(p.get("origin_x", 0.5))))
            oy = max(0.0, min(1.0, float(p.get("origin_y", 0.5))))
            # Zoom by scaling then cropping to original size at offset determined by origin.
            transform = (
                f"scale=iw*{s}:ih*{s},"
                f"crop=iw/{s}:ih/{s}:x=(iw-iw/{s})*{ox}:y=(ih-ih/{s})*{oy}"
            )
            current_label = _segment_transform(
                parts, current_label, t, t_end - t, total_duration, transform, f"zin{uid}"
            )

        elif op_type == "to_vertical":
            try:
                cx = float(p.get("crop_x", 0.5))
            except (TypeError, ValueError):
                cx = 0.5
            cx = max(0.0, min(1.0, cx))
            # Crop to 9:16 (or full frame if already narrower) then pad back to preset size.
            transform = (
                f"crop='min(iw,ih*9/16)':ih:x='(iw-min(iw,ih*9/16))*{cx}':y=0,"
                f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black"
            )
            current_label = _segment_transform(
                parts, current_label, t, t_end - t, total_duration, transform, f"vrt{uid}"
            )

    return current_label


def _apply_audio_ops(cmd, parts, audio_label, flat_ops, n_clip_inputs, slug, total_duration):
    """
    Apply audio_mix and audio_replace. Extra media files become additional
    inputs appended to `cmd`. Returns (new_audio_label, inputs_added_count).
    """
    ops = [o for o in flat_ops if o["type"] in ("audio_mix", "audio_replace")]
    if not ops or not audio_label:
        return audio_label, 0

    inputs_added = 0
    uid = 0
    next_idx = n_clip_inputs

    for op in sorted(ops, key=lambda o: o["tl_start"]):
        p = op.get("params", {}) or {}
        mfid = p.get("media_file_id")
        if not mfid:
            continue
        path = _resolve_media_file_path(slug, mfid)
        if not path or not path.exists():
            continue
        try:
            dur = float(p.get("duration_seconds") or 0)
        except (TypeError, ValueError):
            dur = 0.0
        if dur <= 0:
            continue
        T = max(0.0, float(op["tl_start"]))
        T_end = min(T + dur, total_duration)
        if T_end <= T + 0.01:
            continue

        cmd += ["-i", str(path)]
        uid += 1
        extra_in = f"{next_idx}:a"
        next_idx += 1
        inputs_added += 1

        delay_ms = int(round(T * 1000))
        extra_prepped = f"aex{uid}"
        parts.append(
            f"[{extra_in}]atrim=0:{dur:.3f},asetpts=PTS-STARTPTS,"
            f"adelay={delay_ms}|{delay_ms},apad[{extra_prepped}]"
        )

        if op["type"] == "audio_mix":
            try:
                vol = float(p.get("volume", 0.8))
            except (TypeError, ValueError):
                vol = 0.8
            vol = max(0.0, min(2.0, vol))
            gained = f"aex{uid}g"
            parts.append(f"[{extra_prepped}]volume={vol}[{gained}]")
            mixed = f"amix{uid}"
            parts.append(
                f"[{audio_label}][{gained}]amix=inputs=2:duration=first:normalize=0[{mixed}]"
            )
            audio_label = mixed

        elif op["type"] == "audio_replace":
            muted = f"amute{uid}"
            parts.append(
                f"[{audio_label}]volume='if(between(t,{T:.3f},{T_end:.3f}),0,1)':eval=frame[{muted}]"
            )
            combined = f"arep{uid}"
            parts.append(
                f"[{muted}][{extra_prepped}]amix=inputs=2:duration=first:normalize=0[{combined}]"
            )
            audio_label = combined

    return audio_label, inputs_added


# ---------------------------------------------------------------------------
# Command builder
# ---------------------------------------------------------------------------

def build_ffmpeg_command(slug: str, preset_id: str, output_path: Path):
    """Returns (cmd_list, effective_duration_seconds)."""
    preset = find_preset(preset_id)
    if not preset:
        raise ValueError(f"preset desconocido: {preset_id}")

    clips, flat_ops, all_have_audio, total_duration, moments, audio_lane = _load_timeline_state(slug)
    if not clips:
        raise ValueError("el timeline está vacío")
    if total_duration <= 0.01:
        raise ValueError("la duración total del timeline es 0")

    is_audio_only = preset.get("width") is None
    W = preset.get("width")
    H = preset.get("height")
    fps = preset.get("fps")

    sorted_moments = sorted(moments, key=lambda m: m["timeline_seconds"])

    def next_moment_time(after_t, default):
        for m in sorted_moments:
            if m["timeline_seconds"] > after_t + 1e-6:
                return m["timeline_seconds"] - after_t
        return default - after_t

    cmd = ["ffmpeg", "-y", "-hide_banner"]
    for c in clips:
        cmd += ["-i", str(c["path"])]
    n_media_inputs = len(clips)  # indices used by the source media files

    # For video presets, audio-only clips need a generated black video of the
    # clip's duration. We append those as extra lavfi inputs and keep a map.
    target_fps = fps or 30
    black_idx_map: dict[int, int] = {}  # clip position -> input idx
    next_idx = n_media_inputs
    if not is_audio_only:
        for i, c in enumerate(clips):
            if c["file_type"] != "video":
                cmd += [
                    "-f", "lavfi",
                    "-t", f"{c['duration']:.3f}",
                    "-i", f"color=c=black:s={W}x{H}:r={target_fps}",
                ]
                black_idx_map[i] = next_idx
                next_idx += 1
    n_clip_inputs = next_idx  # everything up to here; extra audio ops will append after

    parts = []

    # ---- Per-segment preprocessing ----
    # Segments reflect the active track at each instant (based on switch_track
    # ops). For single-track projects this is 1:1 with clips; for multi-cam
    # projects the same source clip may appear in several non-contiguous
    # segments.
    segments = _compute_track_segments(clips, moments, flat_ops, total_duration)
    if not segments:
        # Fall back to clips as segments (should not normally happen since
        # we have clips and total_duration > 0).
        segments = [
            {"clip": c, "src_start": c["start_offset"], "src_end": c["end_offset"],
             "tl_start": c["tl_start"], "tl_end": c["tl_end"], "duration": c["duration"]}
            for c in clips
        ]

    clip_idx_by_id = {c["id"]: i for i, c in enumerate(clips)}
    # Count segment uses per source input so we can pre-split shared streams
    # (ffmpeg forbids referencing the same source more than once).
    use_counts_v = {}  # clip_id -> count
    use_counts_a = {}
    use_counts_b = {}  # black input idx -> count (for audio-only-clip-in-video mode)
    for seg in segments:
        c = seg["clip"]
        if is_audio_only:
            if c["has_audio"]:
                use_counts_a[c["id"]] = use_counts_a.get(c["id"], 0) + 1
        else:
            if c["file_type"] == "video":
                use_counts_v[c["id"]] = use_counts_v.get(c["id"], 0) + 1
            else:
                bi = black_idx_map[clip_idx_by_id[c["id"]]]
                use_counts_b[bi] = use_counts_b.get(bi, 0) + 1
            if all_have_audio:
                use_counts_a[c["id"]] = use_counts_a.get(c["id"], 0) + 1

    # Emit split/asplit up front so each segment gets its own labelled copy.
    split_v = {}  # clip_id -> list of labels to pop
    split_a = {}
    split_b = {}  # black idx -> list of labels
    for cid, n in use_counts_v.items():
        i = clip_idx_by_id[cid]
        labels = [f"v{cid}_{j}" for j in range(n)]
        parts.append(f"[{i}:v]split={n}[" + "][".join(labels) + "]")
        split_v[cid] = labels
    for cid, n in use_counts_a.items():
        i = clip_idx_by_id[cid]
        labels = [f"a{cid}_{j}" for j in range(n)]
        parts.append(f"[{i}:a]asplit={n}[" + "][".join(labels) + "]")
        split_a[cid] = labels
    for bi, n in use_counts_b.items():
        labels = [f"b{bi}_{j}" for j in range(n)]
        parts.append(f"[{bi}:v]split={n}[" + "][".join(labels) + "]")
        split_b[bi] = labels

    for k, seg in enumerate(segments):
        c = seg["clip"]
        i = clip_idx_by_id[c["id"]]
        s = float(seg["src_start"])
        e = float(seg["src_end"])
        if is_audio_only:
            if c["has_audio"]:
                src = split_a[c["id"]].pop(0)
                vol = float(c.get("volume", 1.0))
                if abs(vol - 1.0) > 1e-3:
                    parts.append(
                        f"[{src}]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS,"
                        f"volume={vol:.3f}[a{k}]"
                    )
                else:
                    parts.append(
                        f"[{src}]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS[a{k}]"
                    )
        else:
            if c["file_type"] == "video":
                src = split_v[c["id"]].pop(0)
                v_chain = (
                    f"trim=start={s:.3f}:end={e:.3f},setpts=PTS-STARTPTS,"
                    f"fps={target_fps},"
                    f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                    f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2,"
                    f"setsar=1,format=yuv420p"
                )
                parts.append(f"[{src}]{v_chain}[v{k}]")
            else:
                bidx = black_idx_map[i]
                src = split_b[bidx].pop(0)
                seg_dur = seg["duration"]
                parts.append(
                    f"[{src}]trim=start=0:end={seg_dur:.3f},setpts=PTS-STARTPTS,"
                    f"fps={target_fps},scale={W}:{H},setsar=1,format=yuv420p[v{k}]"
                )
            if all_have_audio:
                src = split_a[c["id"]].pop(0)
                vol = float(c.get("volume", 1.0))
                if abs(vol - 1.0) > 1e-3:
                    parts.append(
                        f"[{src}]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS,"
                        f"volume={vol:.3f}[a{k}]"
                    )
                else:
                    parts.append(
                        f"[{src}]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS[a{k}]"
                    )

    # ---- Concat ----
    n_segs = len(segments)
    if is_audio_only:
        if all_have_audio:
            concat_in = "".join(f"[a{k}]" for k in range(n_segs))
            parts.append(f"{concat_in}concat=n={n_segs}:v=0:a=1[aconcat]")
            audio_label = "aconcat"
        else:
            audio_label = None
        video_label = None
    else:
        if all_have_audio:
            concat_in = "".join(f"[v{k}][a{k}]" for k in range(n_segs))
            parts.append(f"{concat_in}concat=n={n_segs}:v=1:a=1[vconcat][aconcat]")
            audio_label = "aconcat"
        else:
            concat_in = "".join(f"[v{k}]" for k in range(n_segs))
            parts.append(f"{concat_in}concat=n={n_segs}:v=1:a=0[vconcat]")
            audio_label = None
        video_label = "vconcat"

    # ---- Video operations ----
    if video_label:
        video_label = _apply_video_ops(
            parts, video_label, flat_ops, total_duration, next_moment_time, W, H
        )

    # ---- Audio operations ----
    if audio_label:
        audio_label, inputs_added = _apply_audio_ops(
            cmd, parts, audio_label, flat_ops, n_clip_inputs, slug, total_duration,
        )
        next_idx_audio = n_clip_inputs + inputs_added
    else:
        next_idx_audio = n_clip_inputs

    # ---- Audio lane (parallel music/SFX mixed in) ----
    if audio_lane:
        lane_labels = []
        for j, lc in enumerate(audio_lane):
            cmd += ["-i", str(lc["path"])]
            input_idx = next_idx_audio
            next_idx_audio += 1
            delay_ms = int(round(float(lc["tl_start"]) * 1000))
            vol = max(0.0, min(2.0, float(lc["volume"] or 0.7)))
            lbl = f"lane{j}"
            parts.append(
                f"[{input_idx}:a]atrim=start={lc['start_offset']:.3f}:end={lc['end_offset']:.3f},"
                f"asetpts=PTS-STARTPTS,"
                f"adelay={delay_ms}|{delay_ms},"
                f"volume={vol}[{lbl}]"
            )
            lane_labels.append(lbl)
        # Mix lane into the existing audio stream (silence bed if none).
        if not audio_label:
            silence_lbl = "asilbed"
            parts.append(
                f"anullsrc=channel_layout=stereo:sample_rate=44100,"
                f"atrim=0:{total_duration:.3f}[{silence_lbl}]"
            )
            audio_label = silence_lbl
        mix_inputs = "[" + audio_label + "]" + "".join(f"[{l}]" for l in lane_labels)
        parts.append(
            f"{mix_inputs}amix=inputs={1 + len(lane_labels)}:duration=first:normalize=0[aout_mix]"
        )
        audio_label = "aout_mix"

    # ---- Final timeline reshape: cut_before / cut_after + jump_to_moment ----
    # All three ops are expressed in original timeline coordinates; we fold
    # them into a single ordered list of keep-ranges and realize it with one
    # split/trim/concat per track.
    keep_ranges = _compute_final_keep_ranges(flat_ops, moments, total_duration)

    if video_label:
        video_label = _apply_final_ranges(
            parts, video_label, keep_ranges, "v", total_duration, "vout"
        )
    if audio_label:
        audio_label = _apply_final_ranges(
            parts, audio_label, keep_ranges, "a", total_duration, "aout"
        )

    effective_from_ranges = sum(e - s for s, e in keep_ranges)

    filter_complex = ";".join(parts)
    cmd += ["-filter_complex", filter_complex]

    if is_audio_only:
        if audio_label:
            cmd += ["-map", f"[{audio_label}]"]
        else:
            # No audio anywhere; append silence input and map it
            cmd += ["-f", "lavfi", "-t", f"{total_duration:.3f}",
                    "-i", "anullsrc=channel_layout=stereo:sample_rate=44100"]
            cmd += ["-map", f"{n_clip_inputs}:a"]
        cmd += ["-vn", "-c:a", preset["acodec"]]
    else:
        cmd += ["-map", f"[{video_label}]"]
        if audio_label:
            cmd += ["-map", f"[{audio_label}]"]
        if preset.get("vcodec"):
            cmd += ["-c:v", preset["vcodec"], "-pix_fmt", "yuv420p"]
        if audio_label and preset.get("acodec"):
            cmd += ["-c:a", preset["acodec"]]
        if preset.get("bitrate"):
            cmd += ["-b:v", preset["bitrate"]]
        cmd += ["-movflags", "+faststart"]

    effective_duration = max(0.001, effective_from_ranges)
    cmd += [str(output_path)]
    return cmd, effective_duration


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

_TIME_RE = re.compile(r"time=(\d+):(\d+):([\d.]+)")


def _update_job(slug: str, job_id: int, **fields):
    # `finished_at_marker` is a sentinel flag, not a real column — strip before writing.
    fields.pop("finished_at_marker", None)
    if not fields:
        return
    db = get_db(slug)
    try:
        cols = ", ".join(f"{k}=?" for k in fields)
        db.execute(f"UPDATE export_jobs SET {cols} WHERE id=?", (*fields.values(), job_id))
        db.commit()
    finally:
        db.close()


def run_export(slug: str, job_id: int):
    db = get_db(slug)
    try:
        db.execute(
            "UPDATE export_jobs SET status='running', started_at=datetime('now') WHERE id=?",
            (job_id,),
        )
        db.commit()
        job = db.execute("SELECT preset_id FROM export_jobs WHERE id=?", (job_id,)).fetchone()
    finally:
        db.close()
    preset_id = job["preset_id"]
    preset = find_preset(preset_id)
    if not preset:
        _update_job(slug, job_id, status="error", error_msg=f"preset desconocido: {preset_id}")
        return

    ext = preset["format"]
    exports_dir = PROJECTS_DIR / slug / "exports"
    exports_dir.mkdir(parents=True, exist_ok=True)
    out_rel = f"{job_id}_{preset_id}.{ext}"
    out_path = exports_dir / out_rel

    try:
        cmd, total_duration = build_ffmpeg_command(slug, preset_id, out_path)
    except Exception as e:
        _update_job(slug, job_id, status="error", error_msg=f"no se pudo construir el comando: {e}")
        return

    log_path = exports_dir / f"{job_id}_{preset_id}.log"
    with log_path.open("w") as f:
        f.write("FFMPEG CMD:\n" + " ".join(repr(a) if " " in a else a for a in cmd) + "\n\n")

    try:
        proc = subprocess.Popen(
            cmd,
            stderr=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            preexec_fn=os.setsid,  # new process group so we can SIGTERM cleanly
        )
    except Exception as e:
        _update_job(slug, job_id, status="error", error_msg=f"no pude lanzar ffmpeg: {e}")
        return

    with _ACTIVE_LOCK:
        _ACTIVE_JOBS[(slug, job_id)] = proc

    last_tail = []
    last_progress = 0
    last_db_write = 0.0
    assert proc.stderr is not None
    try:
        for line in proc.stderr:
            last_tail.append(line.rstrip())
            if len(last_tail) > 60:
                last_tail.pop(0)
            m = _TIME_RE.search(line)
            if m:
                h, mm, ss = int(m.group(1)), int(m.group(2)), float(m.group(3))
                cur = h * 3600 + mm * 60 + ss
                progress = min(99, int(cur / total_duration * 100)) if total_duration > 0 else 0
                if progress > last_progress and (time.time() - last_db_write) > 0.6:
                    last_progress = progress
                    last_db_write = time.time()
                    _update_job(slug, job_id, progress=progress)

        proc.wait()
    finally:
        with _ACTIVE_LOCK:
            _ACTIVE_JOBS.pop((slug, job_id), None)

    with log_path.open("a") as f:
        f.write("\n".join(last_tail) + "\n")

    if proc.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0:
        db = get_db(slug)
        try:
            db.execute(
                "UPDATE export_jobs SET status='done', progress=100, finished_at=datetime('now'), output_file=? WHERE id=?",
                (out_rel, job_id),
            )
            db.commit()
        finally:
            db.close()
    else:
        # Distinguish cancellation from failure. SIGTERM typically yields negative returncode.
        if proc.returncode is not None and proc.returncode < 0:
            _update_job(
                slug, job_id, status="cancelled",
                error_msg=f"cancelado por el usuario (signal {-proc.returncode})",
                finished_at_marker=1,
            )
            # Extra pass to set finished_at via raw SQL
            db = get_db(slug)
            try:
                db.execute(
                    "UPDATE export_jobs SET finished_at=datetime('now') WHERE id=?",
                    (job_id,),
                )
                db.commit()
            finally:
                db.close()
            # Remove partial output
            try:
                if out_path.exists():
                    out_path.unlink()
            except OSError:
                pass
        else:
            tail = "\n".join(last_tail[-25:]) if last_tail else ""
            msg = f"ffmpeg exit={proc.returncode}"
            if tail:
                msg += f"\n{tail[-900:]}"
            _update_job(slug, job_id, status="error", error_msg=msg)


def start_export_thread(slug: str, job_id: int):
    t = threading.Thread(target=run_export, args=(slug, job_id), daemon=True)
    t.start()
    return t
