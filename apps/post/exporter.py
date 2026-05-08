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
            "SELECT id, type, timeline_seconds, duration_seconds, label FROM moments ORDER BY timeline_seconds, id"
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
                    "moment_duration": float(m["duration_seconds"]) if m.get("duration_seconds") else None,
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
# Spotlight: offline speaker-activity analysis
# ---------------------------------------------------------------------------

def _analyze_speaker_activity(clips, total_duration, window=0.3, debounce=1.0,
                               range_start=None, range_end=None):
    """Analyze per-track RMS in ~window-second chunks to detect the active speaker.

    Returns a list of (timestamp, active_track) sorted by time. Each entry
    means "from this timestamp onward, active_track is the loudest speaker."
    The first entry is always at t=0.

    Uses FFmpeg `astats` with reset=1 to get per-frame RMS, then buckets
    frames into windows and averages.
    """
    tracks_used = sorted(set(int(c.get("track", 1)) for c in clips))
    if len(tracks_used) < 2:
        return []

    frame_re = re.compile(r"pts_time:([\d.]+)")
    rms_re = re.compile(r"lavfi\.astats\.Overall\.RMS_level=(-?[\d.]+|inf|-inf)")

    rms_by_track = {}
    for track in tracks_used:
        track_clips = [c for c in clips if int(c.get("track", 1)) == track and c["has_audio"]]
        if not track_clips:
            rms_by_track[track] = []
            continue

        n_windows = max(1, int(total_duration / window))
        window_sums = [0.0] * n_windows
        window_counts = [0] * n_windows

        for tc in track_clips:
            path = tc["path"]
            s = float(tc["start_offset"])
            e = float(tc["end_offset"]) if tc.get("end_offset") is not None else s + tc["duration"]
            tl_start = tc["tl_start"]
            tl_end = tc["tl_end"]
            if range_start is not None and tl_end <= range_start:
                continue
            if range_end is not None and tl_start >= range_end:
                continue
            if range_start is not None and tl_start < range_start:
                s += (range_start - tl_start)
                tl_start = range_start
            if range_end is not None and tl_end > range_end:
                e -= (tl_end - range_end)
            dur = e - s
            if dur <= 0:
                continue

            try:
                proc = subprocess.run(
                    [
                        "ffmpeg", "-v", "info",
                        "-ss", f"{s:.3f}", "-t", f"{dur:.3f}",
                        "-i", str(path),
                        "-af", "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level",
                        "-f", "null", "-",
                    ],
                    capture_output=True, text=True, timeout=120,
                )
            except (subprocess.SubprocessError, OSError):
                continue

            current_pts = None
            for line in (proc.stderr or "").splitlines():
                fm = frame_re.search(line)
                if fm:
                    current_pts = float(fm.group(1))
                rm = rms_re.search(line)
                if rm and current_pts is not None:
                    rms_db_str = rm.group(1)
                    if rms_db_str in ("inf", "-inf"):
                        rms_linear = 0.0
                    else:
                        rms_db = float(rms_db_str)
                        rms_linear = 10.0 ** (rms_db / 20.0) if rms_db > -100 else 0.0
                    abs_t = tl_start + current_pts
                    idx = min(int(abs_t / window), n_windows - 1)
                    if idx >= 0:
                        window_sums[idx] += rms_linear
                        window_counts[idx] += 1
                    current_pts = None

        rms_by_track[track] = [
            (window_sums[i] / window_counts[i]) if window_counts[i] > 0 else 0.0
            for i in range(n_windows)
        ]

    if not rms_by_track or all(not v for v in rms_by_track.values()):
        return []

    n_windows = max(len(v) for v in rms_by_track.values()) if rms_by_track else 0
    for track in rms_by_track:
        while len(rms_by_track[track]) < n_windows:
            rms_by_track[track].append(0.0)

    raw_active = []
    for i in range(n_windows):
        best_track = tracks_used[0]
        best_rms = -1.0
        for track in tracks_used:
            val = rms_by_track[track][i] if i < len(rms_by_track[track]) else 0.0
            if val > best_rms:
                best_rms = val
                best_track = track
        raw_active.append(best_track)

    debounce_windows = max(1, int(debounce / window))
    debounced = []
    current = raw_active[0] if raw_active else tracks_used[0]
    counter = 0
    for val in raw_active:
        if val != current:
            counter += 1
            if counter >= debounce_windows:
                current = val
                counter = 0
        else:
            counter = 0
        debounced.append(current)

    events = []
    prev = None
    for i, track in enumerate(debounced):
        if track != prev:
            events.append((round(i * window, 3), track))
            prev = track

    return events


# ---------------------------------------------------------------------------
# Filter helpers
# ---------------------------------------------------------------------------

def _escape_drawtext(text: str) -> str:
    return (text.replace("\\", "\\\\")
                .replace(":", "\\:")
                .replace("'", "\u2019")
                .replace("%", "\\%"))


def _compute_track_segments(clips, moments, flat_ops, total_duration,
                            compose_multitrack=False, spotlight_events=None):
    """
    Walk the timeline from 0 to total_duration, following switch_track ops to
    determine the active track at each instant, and emit a list of segments
    that describe which source clip (and which sub-range of it) should play
    during each [tl_start, tl_end] window. Segments never overlap.

    compose_multitrack: when True, annotate ALL multitrack segments with
    multi_clips for side-by-side composition (landscape presets). When False,
    only vertical_split segments get multi_clips.

    spotlight_events: list of (timestamp, active_track) from _analyze_speaker_activity.
    When provided, each event timestamp becomes a segment boundary and the
    segment is annotated with spotlight_active_track for 70/30 rendering.
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
        if op["type"] == "switch_track":
            m = moment_by_id.get(op.get("moment_id")) or None
            t = op.get("tl_start")
            if t is None and m is not None:
                t = float(m["timeline_seconds"])
            if t is None:
                continue
            t = float(t)
            bounds.add(t)
            sw_events.append((t, op.get("params") or {}))
        elif op["type"] == "vertical_split":
            t = float(op["tl_start"])
            p = op.get("params") or {}
            dur_raw = p.get("duration_seconds") or op.get("moment_duration")
            dur = float(dur_raw) if dur_raw is not None else (total_duration - t)
            bounds.add(t)
            bounds.add(min(t + dur, total_duration))
    sw_events.sort(key=lambda x: x[0])

    if spotlight_events:
        for (t, _track) in spotlight_events:
            bounds.add(float(t))

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

    # Multitrack annotation: attach clips from ALL tracks to each segment
    # so the renderer can compose them (vstack for vertical_split, hstack
    # for side-by-side). Without switch_track ops, every segment gets
    # multi_clips; with switch_track, only vertical_split segments do.
    has_vsplit = any(op["type"] == "vertical_split" for op in flat_ops)
    has_switch = bool(sw_events)
    tracks_used = sorted(set(int(c.get("track", 1)) for c in clips))

    if len(tracks_used) >= 2:
        vsplit_ranges = []
        if has_vsplit:
            for op in flat_ops:
                if op["type"] != "vertical_split":
                    continue
                t = op["tl_start"]
                p = op.get("params") or {}
                dur_raw = p.get("duration_seconds") or op.get("moment_duration")
                dur = float(dur_raw) if dur_raw is not None else (total_duration - t)
                crop_xs = p.get("crop_xs") or []
                vsplit_ranges.append((t, t + dur, crop_xs))

        def _find_multi_clips(t0, t1):
            mc = []
            for track in tracks_used:
                tc = clip_on_track_at(track, t0)
                if tc and tc["file_type"] == "video":
                    ls = float(tc["start_offset"]) + (t0 - tc["tl_start"])
                    le = float(tc["start_offset"]) + (t1 - tc["tl_start"])
                    mc.append({"clip": tc, "src_start": ls, "src_end": le})
            return mc if len(mc) >= 2 else None

        for seg in segments:
            t0, t1 = seg["tl_start"], seg["tl_end"]
            # Check vsplit ranges first
            in_vsplit = False
            for (vs_start, vs_end, crop_xs) in vsplit_ranges:
                if vs_start - 0.01 <= t0 and t1 <= vs_end + 0.01:
                    mc = _find_multi_clips(t0, t1)
                    if mc:
                        seg["multi_clips"] = mc
                        seg["vsplit_crop_xs"] = crop_xs
                    in_vsplit = True
                    break
            # Side-by-side for all other segments (landscape presets only)
            if not in_vsplit and not has_switch and compose_multitrack:
                mc = _find_multi_clips(t0, t1)
                if mc:
                    seg["multi_clips"] = mc

    # Spotlight annotation: mark each multitrack segment with which track
    # should be emphasized (70% width). Only applies to segments that
    # already have multi_clips.
    if spotlight_events and len(spotlight_events) >= 1:
        for seg in segments:
            if not seg.get("multi_clips"):
                continue
            t0 = seg["tl_start"]
            active = spotlight_events[0][1]
            for (ev_t, ev_track) in spotlight_events:
                if ev_t > t0 + 1e-6:
                    break
                active = ev_track
            seg["spotlight_active_track"] = active

    return segments


def _compute_final_keep_ranges(flat_ops, moments, total_duration, transcript_cuts=None):
    """
    Build the list of (start, end) time ranges in the ORIGINAL timeline that
    should actually reach the final output. Accounts for:
      - jump_to_moment ops: skip [source..target] when target > source;
        backward jumps are ignored in export (would create a loop).
      - cut_before (max tl) and cut_after (min tl): global clamp.
      - transcript_cuts: arbitrary [start, end] ranges produced by the
        transcript editor (delete-word actions). Subtracted from the
        already-computed keep ranges.

    Returns a list of (start, end) pairs, sorted and non-overlapping.
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

    # Subtract transcript-driven deletions. Each (cs, ce) splits any
    # overlapping range into one or two pieces. Ranges entirely inside a
    # cut disappear; ranges that straddle a cut split. Done as a small
    # interval-difference pass — fine for the typical hundreds of cuts a
    # transcript editor produces.
    if transcript_cuts:
        cuts = [(max(0.0, float(s)), max(0.0, float(e))) for s, e in transcript_cuts if e > s]
        cuts.sort()
        # Merge overlapping/adjacent cuts so the diff is monotonic.
        merged_cuts = []
        for cs, ce in cuts:
            if merged_cuts and cs <= merged_cuts[-1][1] + 0.001:
                merged_cuts[-1] = (merged_cuts[-1][0], max(merged_cuts[-1][1], ce))
            else:
                merged_cuts.append((cs, ce))
        result = []
        for s, e in clipped:
            cur_s = s
            for cs, ce in merged_cuts:
                if ce <= cur_s or cs >= e:
                    continue
                if cs > cur_s:
                    result.append((cur_s, min(cs, e)))
                cur_s = max(cur_s, ce)
                if cur_s >= e:
                    break
            if cur_s < e - 0.001:
                result.append((cur_s, e))
        clipped = result if result else []

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


def _apply_vertical_split_segment(parts, current_label, T, D, total, W, H, n, cxs, uid_prefix):
    """
    Take the input video as a side-by-side composite of N panels and re-stack
    those panels vertically into a 9:16 frame at WxH. Each panel gets its own
    crop_x (0..1) for horizontal centering of the face. Applied only during
    [T, T+D]; outside that range, current_label flows through untouched.
    """
    T = max(0.0, float(T))
    T_end = min(float(T) + float(D), total)
    if T_end <= T + 0.01:
        return current_label

    # Output panel dimensions
    out_w_panel = min(W, int(H * 9 / 16))   # the vertical strip width
    panel_h = H // n

    def build_mid_filter(in_label, out_label, prefix):
        """Multi-line filter: split N times, process each panel, vstack."""
        split_outs = [f"{prefix}s{i}" for i in range(n)]
        parts.append(f"[{in_label}]split={n}[" + "][".join(split_outs) + "]")
        panels = []
        for i in range(n):
            cx = cxs[i]
            pl = f"{prefix}p{i}"
            chain = (
                # Slice horizontal panel i out of N
                f"crop=iw/{n}:ih:x=iw*{i}/{n}:y=0,"
                # Scale to fill the target panel area, keeping aspect
                f"scale={out_w_panel}:{panel_h}:force_original_aspect_ratio=increase,"
                # Trim horizontally to exactly out_w_panel using crop_x
                f"crop={out_w_panel}:{panel_h}:x='(iw-{out_w_panel})*{cx}':y=0"
            )
            parts.append(f"[{split_outs[i]}]{chain}[{pl}]")
            panels.append(f"[{pl}]")
        stacked = f"{prefix}vs"
        parts.append(f"{''.join(panels)}vstack=inputs={n}[{stacked}]")
        if out_w_panel < W:
            parts.append(f"[{stacked}]pad={W}:{H}:(ow-iw)/2:0:color=black[{out_label}]")
        else:
            # No horizontal padding needed (preset is already 9:16). Rename via null.
            parts.append(f"[{stacked}]null[{out_label}]")

    # If the op covers the whole stream, no trim/concat needed.
    if T <= 0.01 and T_end >= total - 0.01:
        out_label = f"{uid_prefix}out"
        build_mid_filter(current_label, out_label, uid_prefix)
        return out_label

    # Otherwise: split into before/mid/after, transform mid, concat.
    seg_defs = []
    if T > 0.01:
        seg_defs.append(("before", 0.0, T, False))
    seg_defs.append(("mid", T, T_end, True))
    if T_end < total - 0.01:
        seg_defs.append(("after", T_end, total, False))

    n_seg = len(seg_defs)
    split_labels = [f"{uid_prefix}sg{i}" for i in range(n_seg)]
    parts.append(f"[{current_label}]split={n_seg}[" + "][".join(split_labels) + "]")
    out_labels = []
    for i, (name, start, end, do_transform) in enumerate(seg_defs):
        trimmed = f"{uid_prefix}{name}_t"
        parts.append(
            f"[{split_labels[i]}]trim=start={start:.3f}:end={end:.3f},setpts=PTS-STARTPTS"
            f"[{trimmed}]"
        )
        if do_transform:
            transformed = f"{uid_prefix}{name}_v"
            build_mid_filter(trimmed, transformed, f"{uid_prefix}{name}_")
            out_labels.append(transformed)
        else:
            # Outside the split range: scale/pad to match the W/H output frame.
            scaled = f"{uid_prefix}{name}_s"
            parts.append(
                f"[{trimmed}]scale={W}:{H}:force_original_aspect_ratio=decrease,"
                f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black[{scaled}]"
            )
            out_labels.append(scaled)

    concat_name = f"{uid_prefix}out"
    concat_in = "".join(f"[{x}]" for x in out_labels)
    parts.append(f"{concat_in}concat=n={len(out_labels)}:v=1:a=0[{concat_name}]")
    return concat_name


def _apply_video_ops(parts, current_label, flat_ops, total_duration, next_moment_time, W, H,
                     skip_vsplit=False):
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
        if op_type == "vertical_split" and skip_vsplit:
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

        elif op_type == "vertical_split":
            # Take a side-by-side composite (N panels horizontally) and rebuild
            # it as N panels stacked vertically — fills a 9:16 frame for
            # TikTok/Reels/Shorts. Use with the "tiktok_v" preset (1080x1920).
            try:
                n_panels = int(p.get("n", 2))
            except (TypeError, ValueError):
                n_panels = 2
            n_panels = max(2, min(n_panels, 4))
            crop_xs = p.get("crop_xs") or []
            cxs = []
            for i in range(n_panels):
                try: v = float(crop_xs[i]) if i < len(crop_xs) else 0.5
                except (TypeError, ValueError): v = 0.5
                cxs.append(max(0.0, min(1.0, v)))
            current_label = _apply_vertical_split_segment(
                parts, current_label, t, t_end - t, total_duration,
                W, H, n_panels, cxs, f"vsp{uid}"
            )

        elif op_type == "text_overlay":
            current_label = _apply_text_overlay(parts, current_label, p, t, t_end, W, H, uid)

    return current_label


def _apply_text_overlay(parts, current_label, p, t, t_end, W, H, uid):
    """
    Render a comic text sticker onto a transparent canvas, rotate it, then
    overlay on the main video only during [t, t_end].
    params: text, font, color (#rrggbb), size_pct (0..100 of min(W,H)),
            x_pct, y_pct (0..1, overlay center position),
            rotation_deg (-180..180), outline (bool), shadow (bool),
            animation ("pop" | "shake" | null)
    """
    from config import COMIC_FONTS, DEFAULT_COMIC_FONT
    import math

    text = _escape_drawtext((p.get("text") or "").strip())
    if not text:
        return current_label
    font_key = (p.get("font") or DEFAULT_COMIC_FONT).lower()
    fontfile = COMIC_FONTS.get(font_key) or COMIC_FONTS.get(DEFAULT_COMIC_FONT)
    if not fontfile:
        return current_label

    color = _validate_hex(p.get("color"), "#ffde59")
    try:
        size_pct = float(p.get("size_pct", 18))
    except (TypeError, ValueError):
        size_pct = 18.0
    size_pct = max(2.0, min(60.0, size_pct))
    fontsize = max(12, int(round(min(W, H) * size_pct / 100.0)))
    try:
        x_pct = float(p.get("x_pct", 0.5))
        y_pct = float(p.get("y_pct", 0.5))
    except (TypeError, ValueError):
        x_pct = y_pct = 0.5
    x_pct = max(0.0, min(1.0, x_pct))
    y_pct = max(0.0, min(1.0, y_pct))
    try:
        rot_deg = float(p.get("rotation_deg", 0))
    except (TypeError, ValueError):
        rot_deg = 0.0
    rot_deg = max(-180.0, min(180.0, rot_deg))
    rot_rad = rot_deg * math.pi / 180.0
    outline = bool(p.get("outline", True))
    shadow = bool(p.get("shadow", True))

    # Approximate text-box size (canvas must be big enough for rotation).
    # Conservative: width = len(text)*fontsize*0.7, height = fontsize*1.6.
    approx_w = max(fontsize, int(len(text) * fontsize * 0.75) + 2 * fontsize)
    approx_h = int(fontsize * 2.2)
    diag = int(math.hypot(approx_w, approx_h)) + 16  # square canvas for rotate

    # 1. Transparent canvas with drawtext centered
    canvas_dur = t_end - t
    border_part = ":borderw=6:bordercolor=black" if outline else ""
    shadow_part = ":shadowcolor=black@0.6:shadowx=6:shadowy=8" if shadow else ""
    txt_label = f"txt{uid}"
    parts.append(
        f"color=c=black@0:s={diag}x{diag}:d={canvas_dur:.3f}:r=30,"
        f"format=rgba,"
        f"drawtext=fontfile='{fontfile}':text='{text}'"
        f":fontsize={fontsize}:fontcolor={color}"
        f"{border_part}{shadow_part}"
        f":x=(w-text_w)/2:y=(h-text_h)/2"
        f"[{txt_label}]"
    )

    # 2. Rotate (fillcolor=none keeps transparency)
    rot_label = f"txtR{uid}"
    if abs(rot_deg) > 0.1:
        parts.append(
            f"[{txt_label}]rotate={rot_rad:.4f}:c=none:ow={diag}:oh={diag}[{rot_label}]"
        )
    else:
        parts.append(f"[{txt_label}]null[{rot_label}]")

    # 3. Overlay at (x_pct, y_pct) centered, enabled only in [t, t_end]
    new_label = f"vop{uid}"
    enable = f"between(t,{t:.3f},{t_end:.3f})"
    # overlay x/y position the top-left of the small canvas
    ox = f"(main_w*{x_pct:.4f}-overlay_w/2)"
    oy = f"(main_h*{y_pct:.4f}-overlay_h/2)"
    parts.append(
        f"[{current_label}][{rot_label}]overlay={ox}:{oy}:"
        f"enable='{enable}':format=auto[{new_label}]"
    )
    return new_label


def _resolve_logo_image(slug) -> Path | None:
    """Return the path to the branding logo image, if present."""
    from projects import _read_meta
    meta = _read_meta(slug) or {}
    logo_file = meta.get("logo_filename")
    if logo_file:
        path = PROJECTS_DIR / slug / "branding" / logo_file
        if path.is_file():
            return path
    return None


def _resolve_branding_colors(slug) -> dict:
    """Return branding color dict from project metadata."""
    from projects import _read_meta
    meta = _read_meta(slug) or {}
    branding = (meta.get("source_info") or meta.get("source", {})).get("podcast", {}).get("branding") or {}
    return {
        "primary": branding.get("color_primary") or "#5a8bff",
        "secondary": branding.get("color_secondary") or "#1e2a54",
        "accent": branding.get("color_accent") or "#f4c770",
    }


def _find_moment_label(slug, range_start, range_end):
    """Find the moment label that best matches the export range."""
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT label, timeline_seconds, duration_seconds FROM moments "
            "ORDER BY timeline_seconds"
        ).fetchall()
    finally:
        db.close()
    if not rows:
        return None
    for r in rows:
        t = r["timeline_seconds"]
        dur = r["duration_seconds"] or 0
        if range_start is not None and abs(t - range_start) < 1.0:
            return r["label"]
        if range_start is not None and range_end is not None:
            m_end = t + dur if dur > 0 else t
            if t >= range_start - 0.5 and m_end <= range_end + 0.5:
                return r["label"]
    return None


def _hex_to_ffmpeg(hex_color: str) -> str:
    """Convert #RRGGBB to FFmpeg's 0xRRGGBB format."""
    h = hex_color.lstrip("#")
    if len(h) == 6:
        return f"0x{h}"
    return "0x5a8bff"


def _resolve_podcast_social(slug) -> str | None:
    """Return the podcast's main social handle from source_info branding.
    Picks the first available from: IG, TikTok, Twitter, YouTube.
    Handles both raw usernames and full URLs."""
    import re
    from projects import _read_meta
    meta = _read_meta(slug) or {}
    branding = (meta.get("source_info") or {}).get("podcast", {}).get("branding") or {}
    for key, prefix in [
        ("social_instagram", "@"),
        ("social_tiktok", "@"),
        ("social_twitter", "@"),
        ("social_youtube", "@"),
    ]:
        val = (branding.get(key) or "").strip().rstrip("/")
        if not val:
            continue
        if "/" in val:
            val = val.rsplit("/", 1)[-1]
        val = re.sub(r'^@+', '', val)
        if val:
            return f"{prefix}{val}"
    return None


def _apply_moment_banner(cmd, parts, video_label, slug, total_duration, W, H,
                          range_start, range_end, heading_font=None, body_font=None,
                          banner_position="bottom"):
    """Overlay a CNN-style banner for moment exports: colored bar with podcast
    logo + moment name + social handle. Position: top, middle (between two
    vertical panels), or bottom. Appears for the first 10s with a slide-in."""
    label_text = _find_moment_label(slug, range_start, range_end)
    if not label_text:
        return video_label

    colors = _resolve_branding_colors(slug)
    logo_path = _resolve_logo_image(slug)
    fallback_font = drawtext_fontfile()
    font = _font_part_for(heading_font, fallback_font)

    bar_h = int(H * 0.09)
    text_size = max(18, int(H * 0.032))
    bar_color = _hex_to_ffmpeg(colors["primary"])
    accent_color = _hex_to_ffmpeg(colors["accent"])

    if banner_position == "top":
        bar_y = 0
    elif banner_position == "middle":
        bar_y = (H - bar_h) // 2
    else:
        bar_y = H - bar_h

    show_dur = min(10.0, total_duration)
    slide_dur = 0.4

    enable = f"between(t,0,{show_dur:.3f})"
    if banner_position == "top":
        y_expr = f"if(lt(t,{slide_dur:.3f}),0-{bar_h}+({bar_h})*t/{slide_dur:.3f},{bar_y})"
    elif banner_position == "middle":
        y_expr = str(bar_y)
    else:
        y_expr = f"if(lt(t,{slide_dur:.3f}),{H}-({H}-{bar_y})*t/{slide_dur:.3f},{bar_y})"

    uid = 900

    # 1. Colored bar background
    uid += 1
    bar_lbl = f"mbn{uid}"
    parts.append(
        f"[{video_label}]drawbox=x=0:y='{y_expr}':w={W}:h={bar_h}"
        f":color={bar_color}@0.9:t=fill:enable='{enable}'[{bar_lbl}]"
    )
    video_label = bar_lbl

    # 2. Accent stripe at content-facing edge of bar
    uid += 1
    stripe_lbl = f"mbn{uid}"
    stripe_h = max(3, int(bar_h * 0.05))
    if banner_position == "top":
        stripe_y_expr = f"({y_expr})+{bar_h - stripe_h}"
    else:
        stripe_y_expr = y_expr
    parts.append(
        f"[{video_label}]drawbox=x=0:y='{stripe_y_expr}':w={W}:h={stripe_h}"
        f":color={accent_color}:t=fill:enable='{enable}'[{stripe_lbl}]"
    )
    video_label = stripe_lbl

    # 3. Logo overlay (if available)
    text_x = int(W * 0.04)
    if logo_path:
        logo_idx = sum(1 for a in cmd if a == "-i")
        cmd += ["-i", str(logo_path)]
        logo_size = int(bar_h * 0.85)
        logo_scaled = f"mbn_logo_s"
        parts.append(
            f"[{logo_idx}:v]scale={logo_size}:{logo_size}:force_original_aspect_ratio=decrease,"
            f"format=rgba[{logo_scaled}]"
        )
        uid += 1
        logo_lbl = f"mbn{uid}"
        logo_x = int(W * 0.03)
        logo_y_expr = f"({y_expr})+{int((bar_h - logo_size) / 2)}"
        parts.append(
            f"[{video_label}][{logo_scaled}]overlay=x={logo_x}:y='{logo_y_expr}'"
            f":enable='{enable}'[{logo_lbl}]"
        )
        video_label = logo_lbl
        text_x = logo_x + logo_size + int(W * 0.02)

    # 4. Moment label text
    uid += 1
    txt_lbl = f"mbn{uid}"
    escaped = _escape_drawtext(label_text)
    text_y_expr = f"({y_expr})+{int(bar_h * 0.30)}"
    parts.append(
        f"[{video_label}]drawtext=text='{escaped}'"
        f"{font}:fontsize={text_size}:fontcolor=white"
        f":x={text_x}:y='{text_y_expr}':enable='{enable}'[{txt_lbl}]"
    )
    video_label = txt_lbl

    # 5. Podcast social handle (right-aligned)
    social_handle = _resolve_podcast_social(slug)
    if social_handle:
        social_font = _font_part_for(body_font, fallback_font)
        social_size = max(14, int(H * 0.022))
        uid += 1
        soc_lbl = f"mbn{uid}"
        soc_escaped = _escape_drawtext(social_handle)
        soc_x = f"{W - int(W * 0.03)}-tw"
        soc_y_expr = f"({y_expr})+{int(bar_h * 0.35)}"
        parts.append(
            f"[{video_label}]drawtext=text='{soc_escaped}'"
            f"{social_font}:fontsize={social_size}:fontcolor=white@0.85"
            f":x={soc_x}:y='{soc_y_expr}':enable='{enable}'[{soc_lbl}]"
        )
        video_label = soc_lbl

    return video_label


def _resolve_background_image(slug) -> Path | None:
    """Return the path to the branding background image, if present.
    If the file hasn't been downloaded yet, copy it from prePod's directory."""
    from projects import _read_meta, _write_meta
    meta = _read_meta(slug) or {}
    bg_file = meta.get("background_filename")
    if bg_file:
        path = PROJECTS_DIR / slug / "branding" / bg_file
        if path.is_file():
            return path

    podcast_slug = (
        (meta.get("source") or meta.get("source_info") or {})
        .get("podcast", {}).get("slug")
    )
    if not podcast_slug:
        return None
    import shutil, glob
    prepod_branding = Path("/srv/thepod/prepod/podcasts") / podcast_slug / "branding"
    matches = glob.glob(str(prepod_branding / "background*"))
    if not matches:
        return None
    src = Path(matches[0])
    dest_dir = PROJECTS_DIR / slug / "branding"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"background{src.suffix}"
    try:
        shutil.copy2(str(src), str(dest))
        meta["background_filename"] = dest.name
        _write_meta(slug, meta)
        return dest
    except Exception:
        return None


def _resolve_project_fonts(slug):
    """Read font_heading / font_body from the project's source metadata and
    resolve to local TTF paths. Returns (heading_path, body_path) — either
    may be None if the font isn't configured or download fails."""
    from projects import _read_meta
    meta = _read_meta(slug) or {}
    branding = (meta.get("source_info") or {}).get("podcast", {}).get("branding") or {}
    heading_name = branding.get("font_heading")
    body_name = branding.get("font_body")
    heading_path = body_path = None
    if heading_name or body_name:
        from shared_fonts import resolve_font
        if heading_name:
            heading_path = resolve_font(heading_name, bold=True)
        if body_name:
            body_path = resolve_font(body_name, bold=False)
    return heading_path, body_path


def _font_part_for(font_path, fallback=None):
    """Build the fontfile=... portion of a drawtext filter."""
    path = font_path or fallback
    if path:
        return f":fontfile='{path}'"
    return ""


def _apply_speaker_banners(parts, current_label, participants,
                            total_duration, W, H, *,
                            heading_font=None, show_duration=10.0):
    """Show each participant's name at the start of the video, centered below
    their track's panel. For hstack (W>=H) panels sit side-by-side; for vstack
    (H>W) panels are stacked top-to-bottom. Appears for show_duration seconds
    so it coincides with the moment banner."""
    if not participants or not W or not H:
        return current_label

    track_to_participant = {}
    for p in participants:
        if p.get("track"):
            track_to_participant[int(p["track"])] = p

    if not track_to_participant:
        return current_label

    all_tracks = sorted(track_to_participant.keys())
    n_panels = len(all_tracks)
    if n_panels < 1:
        return current_label

    fallback = drawtext_fontfile()
    name_font_part = _font_part_for(heading_font, fallback)
    uid = 0

    show_dur = min(show_duration, total_duration)
    enable = f"between(t,0,{show_dur:.3f})"
    is_vertical = H > W

    name_size = max(16, int(H * 0.025 if is_vertical else H * 0.032))
    bar_h = int(H * 0.045 if is_vertical else H * 0.055)

    for t_num in all_tracks:
        p = track_to_participant[t_num]
        name = _escape_drawtext(p.get("name") or "")
        if not name:
            continue

        idx = all_tracks.index(t_num)

        if is_vertical:
            panel_h = H // n_panels
            moment_zone = int(H * 0.10)
            bar_y = (idx + 1) * panel_h - bar_h - moment_zone
            bar_x = 0
            bar_w = W
        else:
            panel_w = W // n_panels
            bar_y = int(H * 0.80)
            bar_x = idx * panel_w
            bar_w = panel_w

        nm_x_expr = f"{bar_x}+({bar_w}-tw)/2"

        uid += 1
        bar_lbl = f"bnr{uid}"
        parts.append(
            f"[{current_label}]drawbox=x={bar_x}:y={bar_y}:w={bar_w}:h={bar_h}"
            f":color=black@0.5:t=fill:enable='{enable}'[{bar_lbl}]"
        )
        current_label = bar_lbl

        nm_y = bar_y + int((bar_h - name_size) / 2)
        uid += 1
        nm_lbl = f"bnr{uid}"
        parts.append(
            f"[{current_label}]drawtext=text='{name}'"
            f"{name_font_part}:fontsize={name_size}:fontcolor=white"
            f":x={nm_x_expr}:y={nm_y}:enable='{enable}'[{nm_lbl}]"
        )
        current_label = nm_lbl

    return current_label


def _apply_sponsor_banners(parts, current_label, sponsors, segments,
                            total_duration, W, H, *,
                            heading_font=None, body_font=None):
    """Overlay sponsor name/copy at moments tied to sponsor blocks. Renders a
    small box in the top-right corner for ~5s per occurrence."""
    if not sponsors or not segments or not W or not H:
        return current_label

    sponsor_map = {s["id"]: s for s in sponsors}
    fallback = drawtext_fontfile()
    name_font_part = _font_part_for(heading_font, fallback)
    copy_font_part = _font_part_for(body_font, fallback)
    uid = 0

    cursor = 0.0
    for seg in sorted(segments, key=lambda s: s.get("position", 0)):
        sid = seg.get("sponsor_id")
        if not sid or sid not in sponsor_map:
            cursor += float(seg.get("duration_estimate") or 0)
            continue
        sp = sponsor_map[sid]
        actual = seg.get("actual_offset_seconds")
        t0 = float(actual) if actual is not None else cursor
        dur = 5.0
        t1 = min(t0 + dur, total_duration)
        if t1 - t0 < 0.5:
            cursor += float(seg.get("duration_estimate") or 0)
            continue

        name = _escape_drawtext(sp.get("name") or "")
        if not name:
            cursor += float(seg.get("duration_estimate") or 0)
            continue
        copy_text = _escape_drawtext(sp.get("copy") or "")

        enable = f"between(t,{t0:.3f},{t1:.3f})"
        box_w = int(W * 0.3)
        box_h = int(H * 0.08)
        box_x = W - box_w - int(W * 0.02)
        box_y = int(H * 0.04)

        uid += 1
        bg_lbl = f"spn{uid}"
        parts.append(
            f"[{current_label}]drawbox=x={box_x}:y={box_y}:w={box_w}:h={box_h}"
            f":color=black@0.6:t=fill:enable='{enable}'[{bg_lbl}]"
        )
        current_label = bg_lbl

        uid += 1
        nm_lbl = f"spn{uid}"
        sp_size = max(14, int(H * 0.025))
        parts.append(
            f"[{current_label}]drawtext=text='{name}'"
            f"{name_font_part}:fontsize={sp_size}:fontcolor=white"
            f":x={box_x + 10}:y={box_y + int(box_h * 0.2)}:enable='{enable}'[{nm_lbl}]"
        )
        current_label = nm_lbl

        if copy_text:
            uid += 1
            cp_lbl = f"spn{uid}"
            cp_size = max(11, int(H * 0.018))
            parts.append(
                f"[{current_label}]drawtext=text='{copy_text}'"
                f"{copy_font_part}:fontsize={cp_size}:fontcolor=white@0.7"
                f":x={box_x + 10}:y={box_y + int(box_h * 0.55)}:enable='{enable}'[{cp_lbl}]"
            )
            current_label = cp_lbl

        cursor += float(seg.get("duration_estimate") or 0)

    return current_label


def _apply_topic_lowerthirds(parts, current_label, segments, total_duration, W, H, *,
                              heading_font=None):
    """CNN-style lower-third showing the current segment/topic title. Appears
    for the first ~6s of each segment that has a non-empty title."""
    if not segments or not W or not H:
        return current_label

    fallback = drawtext_fontfile()
    font_part = _font_part_for(heading_font, fallback)
    uid = 0

    cursor = 0.0
    for seg in sorted(segments, key=lambda s: s.get("position", 0)):
        title = (seg.get("title") or "").strip()
        kind = seg.get("kind") or "segment"
        dur_est = float(seg.get("duration_estimate") or 0)
        if not title or kind in ("break",):
            cursor += dur_est
            continue

        t0 = cursor
        show_dur = min(6.0, dur_est) if dur_est > 0 else 6.0
        t1 = min(t0 + show_dur, total_duration)
        if t1 - t0 < 0.5:
            cursor += dur_est
            continue

        escaped = _escape_drawtext(title)
        enable = f"between(t,{t0:.3f},{t1:.3f})"

        bar_y = int(H * 0.88)
        bar_h = int(H * 0.07)
        title_size = max(16, int(H * 0.028))

        uid += 1
        bg_lbl = f"ltrd{uid}"
        parts.append(
            f"[{current_label}]drawbox=x=0:y={bar_y}:w={W}:h={bar_h}"
            f":color=black@0.65:t=fill:enable='{enable}'[{bg_lbl}]"
        )
        current_label = bg_lbl

        uid += 1
        tx_lbl = f"ltrd{uid}"
        tx_x = int(W * 0.04)
        tx_y = bar_y + int(bar_h * 0.25)
        kind_upper = kind.upper()
        label_text = f"{kind_upper}\\: {escaped}" if kind != "segment" else escaped
        parts.append(
            f"[{current_label}]drawtext=text='{label_text}'"
            f"{font_part}:fontsize={title_size}:fontcolor=white"
            f":x={tx_x}:y={tx_y}:enable='{enable}'[{tx_lbl}]"
        )
        current_label = tx_lbl

        cursor += dur_est

    return current_label


def _apply_director_overlays(parts, current_label, slug, total_duration, W, H,
                              heading_font=None):
    """Render director_events as timed lower-third overlays during export.
    Each event with a recording_offset_seconds gets a 6s drawbox+drawtext."""
    if not W or not H:
        return current_label

    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM director_events WHERE recording_offset_seconds IS NOT NULL "
            "ORDER BY recording_offset_seconds"
        ).fetchall()
    finally:
        db.close()

    if not rows:
        return current_label

    fallback = drawtext_fontfile()
    font_part = _font_part_for(heading_font, fallback)
    uid = 0

    type_labels = {
        "banner": "BANNER", "segment": "SEGMENTO", "comment": "COMENTARIO",
        "sponsor": "SPONSOR", "countdown": "COUNTDOWN", "graphic": "GRÁFICO",
        "cue": "CUE",
    }

    for ev in rows:
        t0 = float(ev["recording_offset_seconds"])
        dur = float(ev["duration_seconds"] or 6.0)
        if ev["removed_at"] and ev["injected_at"]:
            try:
                from datetime import datetime as _dt
                injected = _dt.fromisoformat(ev["injected_at"].replace("Z", "+00:00"))
                removed = _dt.fromisoformat(ev["removed_at"].replace("Z", "+00:00"))
                dur = max(1.0, (removed - injected).total_seconds())
            except (ValueError, TypeError):
                pass
        t1 = min(t0 + dur, total_duration)
        if t1 - t0 < 0.3:
            continue

        payload = {}
        if ev["payload"]:
            try:
                payload = json.loads(ev["payload"])
            except (TypeError, ValueError):
                pass

        etype = ev["event_type"] or "overlay"
        prefix = type_labels.get(etype, etype.upper())

        if etype == "banner":
            text = f"{payload.get('name', '')} — {payload.get('title', '')}"
        elif etype == "segment":
            text = payload.get("title", "")
            if payload.get("subtitle"):
                text += f" · {payload['subtitle']}"
        elif etype == "comment":
            text = f"@{payload.get('author', '')}\\: {payload.get('text', '')}"
        elif etype == "sponsor":
            text = f"{payload.get('sponsor_name', '')} — {payload.get('sponsor_copy', '')}"
        elif etype == "cue":
            text = payload.get("cue", "")
        else:
            text = payload.get("caption", "") or payload.get("text", "") or etype

        text = text.strip()
        if not text:
            continue
        escaped = _escape_drawtext(f"{prefix}\\: {text}")
        enable = f"between(t,{t0:.3f},{t1:.3f})"

        bar_y = int(H * 0.85)
        bar_h = int(H * 0.08)
        title_size = max(16, int(H * 0.026))

        uid += 1
        bg_lbl = f"dov{uid}"
        parts.append(
            f"[{current_label}]drawbox=x=0:y={bar_y}:w={W}:h={bar_h}"
            f":color=black@0.7:t=fill:enable='{enable}'[{bg_lbl}]"
        )
        current_label = bg_lbl

        uid += 1
        tx_lbl = f"dov{uid}"
        tx_x = int(W * 0.04)
        tx_y = bar_y + int(bar_h * 0.25)
        parts.append(
            f"[{current_label}]drawtext=text='{escaped}'"
            f"{font_part}:fontsize={title_size}:fontcolor=white"
            f":x={tx_x}:y={tx_y}:enable='{enable}'[{tx_lbl}]"
        )
        current_label = tx_lbl

    return current_label


def _validate_hex(s, default):
    import re as _re
    if not s:
        return default
    s = str(s).strip()
    if _re.fullmatch(r"#[0-9a-fA-F]{6}", s):
        return s
    return default


def _apply_audio_ops(cmd, parts, audio_label, flat_ops, n_clip_inputs, slug, total_duration):
    """
    Apply audio_mix, audio_replace, and text_overlay sound. Extra media files
    become additional inputs appended to `cmd`. Returns
    (new_audio_label, inputs_added_count).
    """
    def _is_audio_op(o):
        if o["type"] in ("audio_mix", "audio_replace"):
            return True
        if o["type"] == "text_overlay":
            return bool((o.get("params") or {}).get("sound_file_id"))
        return False
    ops = [o for o in flat_ops if _is_audio_op(o)]
    if not ops or not audio_label:
        return audio_label, 0

    inputs_added = 0
    uid = 0
    next_idx = n_clip_inputs

    for op in sorted(ops, key=lambda o: o["tl_start"]):
        p = op.get("params", {}) or {}
        if op["type"] == "text_overlay":
            mfid = p.get("sound_file_id")
        else:
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

        elif op["type"] == "text_overlay":
            try:
                svol = float(p.get("sound_volume", 1.0))
            except (TypeError, ValueError):
                svol = 1.0
            svol = max(0.0, min(2.0, svol))
            gained = f"aex{uid}g"
            parts.append(f"[{extra_prepped}]volume={svol}[{gained}]")
            mixed = f"atxt{uid}"
            parts.append(
                f"[{audio_label}][{gained}]amix=inputs=2:duration=first:normalize=0[{mixed}]"
            )
            audio_label = mixed

    return audio_label, inputs_added


# ---------------------------------------------------------------------------
# Command builder
# ---------------------------------------------------------------------------

def build_ffmpeg_command(slug: str, preset_id: str, output_path: Path,
                         burn_captions=None, enhance_speech: bool = False,
                         range_start: float | None = None,
                         range_end: float | None = None,
                         spotlight: bool = False,
                         use_background: bool = False,
                         moment_banner: bool = False,
                         banner_position: str = "bottom",
                         vertical_center_spotlight: bool = False,
                         director_overlays: bool = False):
    """Returns (cmd_list, effective_duration_seconds).

    `enhance_speech`: when True, runs the speech track through a small
    "studio in a box" chain (highpass + denoise + presence EQ +
    compression) before mixing with the audio lane, then loudness-normalizes
    the final bus to -16 LUFS. Designed to give a cleaner podcast voice
    without the user touching any DSP knobs.

    `range_start` / `range_end`: optional partial-export window (timeline
    seconds). Anything outside is discarded; cuts/transcript_cuts/zooms that
    fall inside the window are preserved. Set both for a closed range; one
    by itself is treated as half-open.

    `spotlight`: when True and the timeline has 2+ tracks in a landscape
    preset, run offline RMS analysis to detect the active speaker per
    segment; the active speaker gets ~70% of the frame width.
    """
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

    # Compute keep_ranges early so we can pre-filter lane clips (and
    # eventually segments) that fall entirely outside the export window.
    # This avoids feeding FFmpeg dozens of useless amix inputs.
    db_cuts = get_db(slug)
    try:
        cut_rows = db_cuts.execute(
            "SELECT start_seconds, end_seconds FROM transcript_cuts ORDER BY start_seconds"
        ).fetchall()
        transcript_cuts = [(r["start_seconds"], r["end_seconds"]) for r in cut_rows]
    finally:
        db_cuts.close()

    keep_ranges = _compute_final_keep_ranges(
        flat_ops, moments, total_duration, transcript_cuts=transcript_cuts,
    )
    if range_start is not None or range_end is not None:
        rs = max(0.0, float(range_start)) if range_start is not None else 0.0
        re_ = min(total_duration, float(range_end)) if range_end is not None else total_duration
        if re_ > rs + 0.01:
            clipped = []
            for s, e in keep_ranges:
                cs = max(s, rs)
                ce = min(e, re_)
                if ce > cs + 0.01:
                    clipped.append((cs, ce))
            keep_ranges = clipped if clipped else [(rs, re_)]

    def _overlaps_keep(t0, t1):
        for kr_s, kr_e in keep_ranges:
            overlap = min(t1, kr_e) - max(t0, kr_s)
            if overlap > 0.01:
                return True
        return False

    audio_lane = [lc for lc in audio_lane if _overlaps_keep(lc["tl_start"], lc["tl_end"])]

    cmd = ["ffmpeg", "-y", "-hide_banner"]
    seek_offset = 0.0  # set after segments are computed
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
    is_landscape = not is_audio_only and W is not None and H is not None and W >= H
    if is_landscape:
        banner_position = "bottom"
    if vertical_center_spotlight:
        banner_position = "bottom"
    tracks_used = sorted(set(int(c.get("track", 1)) for c in clips))
    is_multitrack = len(tracks_used) >= 2

    spotlight_events = None
    if spotlight and (is_landscape or vertical_center_spotlight) and is_multitrack:
        spotlight_events = _analyze_speaker_activity(clips, total_duration,
                                                       range_start=range_start, range_end=range_end)

    segments = _compute_track_segments(
        clips, moments, flat_ops, total_duration,
        compose_multitrack=(is_landscape or is_multitrack or vertical_center_spotlight),
        spotlight_events=spotlight_events,
    )
    if not segments:
        # Fall back to clips as segments (should not normally happen since
        # we have clips and total_duration > 0).
        segments = [
            {"clip": c, "src_start": c["start_offset"], "src_end": c["end_offset"],
             "tl_start": c["tl_start"], "tl_end": c["tl_end"], "duration": c["duration"]}
            for c in clips
        ]

    # Pre-filter AND clip segments to keep_ranges so FFmpeg only decodes
    # the source data actually needed for the export window. Without clipping,
    # a segment spanning 0-71 s would be decoded in full even for a 10 s range.
    if keep_ranges:
        kr_min = min(kr_s for kr_s, _ in keep_ranges)
        kr_max = max(kr_e for _, kr_e in keep_ranges)
        clipped_segs = []
        changed = False
        for seg in segments:
            tl_s = seg["tl_start"]
            tl_e = seg["tl_end"]
            if tl_e <= kr_min + 0.001 or tl_s >= kr_max - 0.001:
                changed = True
                continue
            new_tl_s = max(tl_s, kr_min)
            new_tl_e = min(tl_e, kr_max)
            if new_tl_e <= new_tl_s + 0.001:
                changed = True
                continue
            if new_tl_s > tl_s + 0.001 or new_tl_e < tl_e - 0.001:
                changed = True
                seg = dict(seg)
                offset_start = new_tl_s - tl_s
                offset_end = tl_e - new_tl_e
                seg["src_start"] = float(seg["src_start"]) + offset_start
                seg["src_end"] = float(seg["src_end"]) - offset_end
                seg["tl_start"] = new_tl_s
                seg["tl_end"] = new_tl_e
                seg["duration"] = new_tl_e - new_tl_s
                mc = seg.get("multi_clips")
                if mc:
                    mc = [dict(e) for e in mc]
                    for entry in mc:
                        entry["src_start"] = float(entry["src_start"]) + offset_start
                        entry["src_end"] = float(entry["src_end"]) - offset_end
                    seg["multi_clips"] = mc
            clipped_segs.append(seg)
        if clipped_segs and changed:
            segments = clipped_segs
    else:
        changed = False
    if changed:
        concat_cursor = 0.0
        seg_map = []
        for seg in segments:
            dur = seg["tl_end"] - seg["tl_start"]
            seg_map.append((seg["tl_start"], seg["tl_end"], concat_cursor, concat_cursor + dur))
            concat_cursor += dur

        def _remap_ranges(ranges):
            out = []
            for kr_s, kr_e in ranges:
                for o_s, o_e, c_s, _c_e in seg_map:
                    is_s = max(kr_s, o_s)
                    is_e = min(kr_e, o_e)
                    if is_e > is_s + 0.001:
                        out.append((c_s + (is_s - o_s), c_s + (is_e - o_s)))
            out.sort()
            merged = []
            for s, e in out:
                if merged and s <= merged[-1][1] + 0.001:
                    merged[-1] = (merged[-1][0], max(merged[-1][1], e))
                else:
                    merged.append((s, e))
            return merged

        keep_ranges = _remap_ranges(keep_ranges)
        total_duration = concat_cursor

        remapped_ops = []
        for op in flat_ops:
            t = op["tl_start"]
            for o_s, o_e, c_s, _c_e in seg_map:
                if o_s - 0.01 <= t < o_e + 0.01:
                    remapped_ops.append({**op, "tl_start": c_s + (t - o_s)})
                    break
        flat_ops = remapped_ops

        remapped_lane = []
        for lc in audio_lane:
            t0 = lc["tl_start"]
            t1 = lc["tl_end"]
            for o_s, o_e, c_s, _c_e in seg_map:
                if t0 < o_e and t1 > o_s:
                    offset = c_s - o_s
                    remapped_lane.append({
                        **lc,
                        "tl_start": max(0.0, t0 + offset),
                        "tl_end": t1 + offset,
                    })
                    break
        audio_lane = remapped_lane

    # ---- Input-level seeking optimisation ----
    # When all segments start far into the source files (e.g. range export
    # at 71 s), add -ss before each media input so FFmpeg keyframe-seeks
    # instead of decoding+discarding from second 0.
    if range_start is not None:
        all_src_starts = []
        for seg in segments:
            mc = seg.get("multi_clips")
            if mc:
                all_src_starts.extend(float(entry["src_start"]) for entry in mc)
            else:
                all_src_starts.append(float(seg["src_start"]))
        min_src = min(all_src_starts) if all_src_starts else 0.0
        if min_src > 10.0:
            seek_offset = max(0.0, min_src - 3.0)
            # Insert -ss before each media -i in the already-built cmd.
            rebuilt = ["ffmpeg", "-y", "-hide_banner"]
            i = 3  # skip header
            while i < len(cmd):
                if cmd[i] == "-i" and i + 1 < len(cmd) and not cmd[i + 1].startswith("color="):
                    rebuilt += ["-ss", f"{seek_offset:.3f}"]
                rebuilt.append(cmd[i])
                i += 1
            cmd[:] = rebuilt

    clip_idx_by_id = {c["id"]: i for i, c in enumerate(clips)}
    # Count segment uses per source input so we can pre-split shared streams
    # (ffmpeg forbids referencing the same source more than once).
    use_counts_v = {}  # clip_id -> count
    use_counts_a = {}
    use_counts_b = {}  # black input idx -> count (for audio-only-clip-in-video mode)
    has_multitrack_vsplit = False
    for seg in segments:
        c = seg["clip"]
        mc = seg.get("multi_clips")
        if is_audio_only:
            if c["has_audio"]:
                use_counts_a[c["id"]] = use_counts_a.get(c["id"], 0) + 1
        else:
            if mc:
                has_multitrack_vsplit = True
                for entry in mc:
                    ec = entry["clip"]
                    use_counts_v[ec["id"]] = use_counts_v.get(ec["id"], 0) + 1
                    if all_have_audio:
                        use_counts_a[ec["id"]] = use_counts_a.get(ec["id"], 0) + 1
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

    # ---- Background image: single input, overlay after concat ----
    # Segments use transparent padding (yuva420p + color=black@0.0) so the
    # bg shows through gaps.  One post-concat overlay composites the result
    # onto a looped bg frame.  This avoids the per-segment loop+overlay
    # approach that deadlocked with concat's sequential consumption.
    bg_input_idx = None
    has_bg = False
    if use_background and not is_audio_only and W and H:
        bg_path = _resolve_background_image(slug)
        if bg_path:
            cmd += ["-i", str(bg_path)]
            bg_input_idx = n_clip_inputs
            n_clip_inputs += 1
            has_bg = True

    for k, seg in enumerate(segments):
        c = seg["clip"]
        mc = seg.get("multi_clips")
        i = clip_idx_by_id[c["id"]]
        s = float(seg["src_start"]) - seek_offset
        e = float(seg["src_end"]) - seek_offset
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
        elif vertical_center_spotlight and mc and W and H:
            # VERTICAL CENTER SPOTLIGHT: render only the active speaker's
            # track filling the entire frame. Each segment shows one track.
            spotlight_track = seg.get("spotlight_active_track")
            chosen = None
            for entry in mc:
                t_num = int(entry["clip"].get("track", 1))
                if t_num == spotlight_track:
                    chosen = entry
                    break
            if chosen is None:
                chosen = mc[0]

            for entry in mc:
                if entry is not chosen:
                    ec_skip = entry["clip"]
                    skipped = split_v[ec_skip["id"]].pop(0)
                    parts.append(f"[{skipped}]nullsink")

            ec = chosen["clip"]
            es = float(chosen["src_start"]) - seek_offset
            ee = float(chosen["src_end"]) - seek_offset
            src = split_v[ec["id"]].pop(0)

            if has_bg:
                v_chain = (
                    f"trim=start={es:.3f}:end={ee:.3f},setpts=PTS-STARTPTS,"
                    f"fps={target_fps},"
                    f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                    f"format=yuva420p,"
                    f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black@0.0,"
                    f"setsar=1"
                )
            else:
                v_chain = (
                    f"trim=start={es:.3f}:end={ee:.3f},setpts=PTS-STARTPTS,"
                    f"fps={target_fps},"
                    f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                    f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2,"
                    f"setsar=1,format=yuv420p"
                )
            parts.append(f"[{src}]{v_chain}[v{k}]")

            # Audio: mix all tracks (even though only one is shown visually)
            if all_have_audio:
                a_labels = []
                for j, entry in enumerate(mc):
                    ec2 = entry["clip"]
                    es2 = float(entry["src_start"]) - seek_offset
                    ee2 = float(entry["src_end"]) - seek_offset
                    src_a = split_a[ec2["id"]].pop(0)
                    vol = float(ec2.get("volume", 1.0))
                    al = f"ma{k}_{j}"
                    if abs(vol - 1.0) > 1e-3:
                        parts.append(
                            f"[{src_a}]atrim=start={es2:.3f}:end={ee2:.3f},asetpts=PTS-STARTPTS,"
                            f"volume={vol:.3f}[{al}]"
                        )
                    else:
                        parts.append(
                            f"[{src_a}]atrim=start={es2:.3f}:end={ee2:.3f},asetpts=PTS-STARTPTS[{al}]"
                        )
                    a_labels.append(f"[{al}]")
                if len(a_labels) == 1:
                    parts.append(f"{a_labels[0]}anull[a{k}]")
                else:
                    parts.append(f"{''.join(a_labels)}amix=inputs={len(a_labels)}:normalize=0[a{k}]")
            else:
                src_a = split_a[mc[0]["clip"]["id"]].pop(0)
                s_a = float(mc[0]["src_start"]) - seek_offset
                e_a = float(mc[0]["src_end"]) - seek_offset
                parts.append(f"[{src_a}]atrim=start={s_a:.3f}:end={e_a:.3f},asetpts=PTS-STARTPTS[a{k}]")

        elif mc and W and H:
            # Multitrack composition: vstack for vertical_split (9:16),
            # hstack side-by-side for standard presets (16:9).
            n_panels = len(mc)
            vsplit_cxs = seg.get("vsplit_crop_xs")
            is_vsplit = H > W

            spotlight_track = seg.get("spotlight_active_track")

            # Compute per-panel widths for hstack. When spotlight is active,
            # the active speaker's panel gets ~70% of W, others share ~30%.
            if not is_vsplit and spotlight_track and n_panels >= 2:
                active_w = int(W * 0.7)
                remaining = W - active_w
                inactive_w = remaining // (n_panels - 1)
                panel_widths = []
                for j, entry in enumerate(mc):
                    t_num = int(entry["clip"].get("track", 1))
                    panel_widths.append(active_w if t_num == spotlight_track else inactive_w)
                pw_sum = sum(panel_widths)
                if pw_sum != W:
                    panel_widths[-1] += (W - pw_sum)
            else:
                panel_widths = [W // n_panels] * n_panels
                pw_sum = sum(panel_widths)
                if pw_sum != W:
                    panel_widths[-1] += (W - pw_sum)

            panel_labels = []
            for j, entry in enumerate(mc):
                ec = entry["clip"]
                es = float(entry["src_start"]) - seek_offset
                ee = float(entry["src_end"]) - seek_offset
                src = split_v[ec["id"]].pop(0)
                pl = f"mp{k}_{j}"
                if is_vsplit:
                    out_w = min(W, int(H * 9 / 16))
                    panel_h = H // n_panels
                    cx = 0.5
                    if vsplit_cxs and j < len(vsplit_cxs):
                        try:
                            cx = max(0.0, min(1.0, float(vsplit_cxs[j])))
                        except (TypeError, ValueError):
                            pass
                    chain = (
                        f"trim=start={es:.3f}:end={ee:.3f},setpts=PTS-STARTPTS,"
                        f"fps={target_fps},"
                        f"scale={out_w}:{panel_h}:force_original_aspect_ratio=increase,"
                        f"crop={out_w}:{panel_h}:x='(iw-{out_w})*{cx}':y=0,"
                        f"setsar=1,format=yuv420p"
                    )
                else:
                    pw = panel_widths[j]
                    if has_bg:
                        chain = (
                            f"trim=start={es:.3f}:end={ee:.3f},setpts=PTS-STARTPTS,"
                            f"fps={target_fps},"
                            f"scale={pw}:{H}:force_original_aspect_ratio=decrease,"
                            f"format=yuva420p,"
                            f"pad={pw}:{H}:(ow-iw)/2:(oh-ih)/2:color=black@0.0,"
                            f"setsar=1"
                        )
                    else:
                        chain = (
                            f"trim=start={es:.3f}:end={ee:.3f},setpts=PTS-STARTPTS,"
                            f"fps={target_fps},"
                            f"scale={pw}:{H}:force_original_aspect_ratio=decrease,"
                            f"pad={pw}:{H}:(ow-iw)/2:(oh-ih)/2,"
                            f"setsar=1,format=yuv420p"
                        )
                parts.append(f"[{src}]{chain}[{pl}]")
                panel_labels.append(f"[{pl}]")

            comp = f"comp{k}"
            if is_vsplit:
                parts.append(f"{''.join(panel_labels)}vstack=inputs={n_panels}[{comp}]")
                out_w = min(W, int(H * 9 / 16))
                if has_bg and out_w < W:
                    parts.append(
                        f"[{comp}]format=yuva420p,"
                        f"pad={W}:{H}:(ow-iw)/2:0:color=black@0.0,"
                        f"setsar=1[v{k}]"
                    )
                elif out_w < W:
                    parts.append(f"[{comp}]pad={W}:{H}:(ow-iw)/2:0:color=black,setsar=1,format=yuv420p[v{k}]")
                else:
                    parts.append(f"[{comp}]setsar=1,format=yuv420p[v{k}]")
            else:
                parts.append(f"{''.join(panel_labels)}hstack=inputs={n_panels}[v{k}]")

            # Audio: mix all tracks
            if all_have_audio:
                a_labels = []
                for j, entry in enumerate(mc):
                    ec = entry["clip"]
                    es = float(entry["src_start"]) - seek_offset
                    ee = float(entry["src_end"]) - seek_offset
                    src_a = split_a[ec["id"]].pop(0)
                    vol = float(ec.get("volume", 1.0))
                    al = f"ma{k}_{j}"
                    if abs(vol - 1.0) > 1e-3:
                        parts.append(
                            f"[{src_a}]atrim=start={es:.3f}:end={ee:.3f},asetpts=PTS-STARTPTS,"
                            f"volume={vol:.3f}[{al}]"
                        )
                    else:
                        parts.append(
                            f"[{src_a}]atrim=start={es:.3f}:end={ee:.3f},asetpts=PTS-STARTPTS[{al}]"
                        )
                    a_labels.append(f"[{al}]")
                if len(a_labels) > 1:
                    parts.append(f"{''.join(a_labels)}amix=inputs={len(a_labels)}:normalize=0[a{k}]")
                else:
                    parts.append(f"{a_labels[0]}anull[a{k}]")
        else:
            if c["file_type"] == "video":
                src = split_v[c["id"]].pop(0)
                if has_bg:
                    v_chain = (
                        f"trim=start={s:.3f}:end={e:.3f},setpts=PTS-STARTPTS,"
                        f"fps={target_fps},"
                        f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                        f"format=yuva420p,"
                        f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black@0.0,"
                        f"setsar=1"
                    )
                else:
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
                fmt = "yuva420p" if has_bg else "yuv420p"
                parts.append(
                    f"[{src}]trim=start=0:end={seg_dur:.3f},setpts=PTS-STARTPTS,"
                    f"fps={target_fps},scale={W}:{H},setsar=1,format={fmt}[v{k}]"
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

    # ---- Background overlay (single post-concat pass) ----
    if video_label and has_bg and bg_input_idx is not None:
        parts.append(
            f"[{bg_input_idx}:v]scale={W}:{H},setsar=1,format=yuv420p,"
            f"loop=-1:1:0,setpts=N/{target_fps}/TB[bgloop]"
        )
        parts.append(
            f"[bgloop][{video_label}]overlay=0:0:shortest=1,"
            f"format=yuv420p[vbg]"
        )
        video_label = "vbg"

    # ---- Video operations ----
    if video_label:
        video_label = _apply_video_ops(
            parts, video_label, flat_ops, total_duration, next_moment_time, W, H,
            skip_vsplit=has_multitrack_vsplit,
        )

    # ---- Overlay banners (speaker / sponsor / topic) ----
    if video_label and not is_audio_only:
        db_bnr = get_db(slug)
        try:
            p_rows = db_bnr.execute(
                "SELECT * FROM project_participants ORDER BY id"
            ).fetchall()
            participants = [dict(r) for r in p_rows]

            # Re-derive participant→track from actual timeline media files.
            # The stored track field may not match (e.g. import order ≠
            # timeline order). Match first name against original_name.
            if participants:
                trk_rows = db_bnr.execute(
                    "SELECT DISTINCT tc.track, mf.original_name "
                    "FROM timeline_clips tc "
                    "JOIN media_files mf ON mf.id = tc.media_file_id "
                    "WHERE mf.file_type='video' ORDER BY tc.track"
                ).fetchall()
                track_orignames = {int(r["track"]): r["original_name"].lower() for r in trk_rows}
                for p in participants:
                    first = (p.get("name") or "").split()[0].lower()
                    if not first:
                        continue
                    for t, orig in track_orignames.items():
                        if first in orig:
                            p["track"] = t
                            break

            sp_rows = db_bnr.execute(
                "SELECT * FROM project_sponsors ORDER BY position, id"
            ).fetchall()
            proj_sponsors = [dict(r) for r in sp_rows]

            seg_rows = db_bnr.execute(
                "SELECT ps.*, sp.name AS sponsor_name "
                "FROM project_segments ps "
                "LEFT JOIN project_sponsors sp ON sp.id = ps.sponsor_id "
                "ORDER BY ps.position, ps.id"
            ).fetchall()
            proj_segments = [dict(r) for r in seg_rows]
        finally:
            db_bnr.close()

        heading_font, body_font = _resolve_project_fonts(slug)

        if is_multitrack and participants:
            video_label = _apply_speaker_banners(
                parts, video_label, participants,
                total_duration, W, H,
                heading_font=heading_font,
                show_duration=5.0,
            )
        if proj_sponsors and proj_segments:
            video_label = _apply_sponsor_banners(
                parts, video_label, proj_sponsors, proj_segments,
                total_duration, W, H,
                heading_font=heading_font, body_font=body_font,
            )
        if proj_segments:
            video_label = _apply_topic_lowerthirds(
                parts, video_label, proj_segments, total_duration, W, H,
                heading_font=heading_font,
            )

    # ---- Director overlays (timed lower-thirds from prodPod director events) ----
    if video_label and not is_audio_only and director_overlays:
        h_font = _resolve_project_fonts(slug)[0]
        video_label = _apply_director_overlays(
            parts, video_label, slug, total_duration, W, H,
            heading_font=h_font,
        )

    # ---- Moment banner (CNN-style bar with logo + label + social) ----
    if video_label and not is_audio_only and moment_banner and range_start is not None:
        n_before = sum(1 for a in cmd if a == "-i")
        h_font, b_font = _resolve_project_fonts(slug)
        video_label = _apply_moment_banner(
            cmd, parts, video_label, slug, total_duration, W, H,
            range_start, range_end, heading_font=h_font, body_font=b_font,
            banner_position=banner_position,
        )
        n_clip_inputs += sum(1 for a in cmd if a == "-i") - n_before

    # ---- Speech enhancement (voice-only chain) ----
    # Applied here, between segment concat and any audio ops, so it ONLY
    # touches the speech track (timeline_clips). Music bed and SFX from the
    # audio lane are mixed in later and intentionally bypass these filters
    # — compressing/EQ-ing the music would corrupt it. The final bus still
    # gets loudnorm at the end of the chain regardless.
    #
    # Chain rationale:
    #   highpass=80   → removes mic rumble and HVAC bleed
    #   afftdn nr=12  → gentle FFT denoise (preserves consonants)
    #   equalizer 4k  → small presence boost (3–5 kHz)
    #   acompressor   → 3:1 above ~-18 dBFS, 20/200ms, +2 dB makeup
    if audio_label and enhance_speech:
        parts.append(
            f"[{audio_label}]"
            f"highpass=f=80,"
            f"afftdn=nr=12,"
            f"equalizer=f=4000:t=q:w=1.5:g=3,"
            f"acompressor=threshold=0.1259:ratio=3:attack=20:release=200:makeup=2"
            f"[aenh]"
        )
        audio_label = "aenh"

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

    # ---- Final timeline reshape ----
    # keep_ranges was computed early (before the filter graph) so we could
    # pre-filter lane clips. Apply it now to trim the concat output.
    if video_label:
        video_label = _apply_final_ranges(
            parts, video_label, keep_ranges, "v", total_duration, "vout"
        )
    if audio_label:
        audio_label = _apply_final_ranges(
            parts, audio_label, keep_ranges, "a", total_duration, "aout"
        )

    # ---- Final loudness normalize (–16 LUFS, podcast standard) ----
    # Single-pass loudnorm: a measure-then-apply pass would be ideal but
    # would double export time. Single-pass is what most one-click "studio"
    # buttons ship with and is plenty for spoken-word content.
    if audio_label and enhance_speech:
        parts.append(
            f"[{audio_label}]loudnorm=I=-16:TP=-1.5:LRA=11[aloud]"
        )
        audio_label = "aloud"

    # Burn-in captions: append a `subtitles=` filter on the final video stream
    # using the SRT sidecar of the requested media file.
    if video_label and burn_captions:
        from db import get_db as _get_db
        db = _get_db(slug)
        try:
            mf = db.execute(
                "SELECT filename, file_type FROM media_files WHERE id=?",
                (burn_captions.get("media_file_id"),),
            ).fetchone()
        finally:
            db.close()
        if mf:
            srt_path = (
                PROJECTS_DIR / slug / "media" / mf["file_type"]
                / f"{mf['filename']}.{burn_captions.get('language')}.srt"
            )
            if srt_path.is_file():
                # Single-quote-escape the path for the filter expression.
                srt_arg = str(srt_path).replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
                parts.append(
                    f"[{video_label}]subtitles='{srt_arg}'"
                    f":force_style='Fontsize=22,PrimaryColour=&Hffffff&,OutlineColour=&H000000&,BorderStyle=3,Outline=2'"
                    f"[vsub]"
                )
                video_label = "vsub"

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
            if preset.get("crf"):
                cmd += ["-crf", preset["crf"]]
            if preset.get("x264_preset"):
                cmd += ["-preset", preset["x264_preset"]]
            cmd += ["-threads", "0"]
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


def _fmt_timestamp(seconds: float) -> str:
    """0:00 / 12:34 / 1:02:03 — YouTube-compatible (Spotify and Apple accept it too).

    YouTube needs the first chapter at exactly "0:00" for chapter parsing
    to activate, and uses H:MM:SS once the show passes one hour.
    """
    s = max(0, int(round(seconds or 0)))
    h, rem = divmod(s, 3600)
    m, ss = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{ss:02d}"
    return f"{m}:{ss:02d}"


def _write_notes_file(slug: str, job_id: int, preset_id: str, exports_dir: Path) -> str:
    """Generate a sidecar `.txt` next to the export with title, description,
    chapters (from `moments`), and credits. Returns the file's basename
    (relative to exports_dir) so it can be stored on the job row.

    The chapters come from the project's `moments` table (those imported
    from prodPod by `import_chapters_from_prodpod`). We use the timeline
    offset directly — moments live on the same timeline as the rendered
    output, so no remapping is needed.
    """
    # Project metadata (proyecto.json holds the name + extra_hosts list)
    name = slug
    description = ""
    owner = None
    extras: list[str] = []
    try:
        from projects import _read_meta as _pp_read_meta
        meta = _pp_read_meta(slug) or {}
        name = (meta.get("name") or slug).strip() or slug
        description = (meta.get("description") or "").strip()
        owner = (meta.get("owner_username") or "").strip() or None
        raw_extras = meta.get("extra_hosts") or []
        if isinstance(raw_extras, list):
            extras = [str(x).strip() for x in raw_extras if str(x).strip()]
    except Exception:
        pass

    # Chapters from moments — both 'relative' and 'absolute' types live on
    # the timeline; sort by their `timeline_seconds` either way.
    db = get_db(slug)
    try:
        chap_rows = db.execute(
            "SELECT timeline_seconds, label FROM moments "
            "WHERE label IS NOT NULL AND TRIM(label) <> '' "
            "ORDER BY timeline_seconds, id"
        ).fetchall()
    finally:
        db.close()

    lines: list[str] = []
    lines.append(name)
    lines.append("")
    if description:
        lines.append(description)
        lines.append("")

    if chap_rows:
        lines.append("Capítulos")
        for r in chap_rows:
            ts = _fmt_timestamp(r["timeline_seconds"])
            label = (r["label"] or "").strip() or "—"
            lines.append(f"{ts} {label}")
        lines.append("")
    else:
        lines.append("Capítulos")
        lines.append("(No se importaron marcadores de capítulo desde prodPod.)")
        lines.append("")

    credits_lines = []
    if owner:
        credits_lines.append(owner)
    credits_lines.extend([h for h in extras if h != owner])
    if credits_lines:
        lines.append("Créditos")
        for who in credits_lines:
            lines.append(f"• {who}")
        lines.append("")

    notes_rel = f"{job_id}_{preset_id}.notes.txt"
    notes_path = exports_dir / notes_rel
    notes_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return notes_rel


def run_export(slug: str, job_id: int):
    db = get_db(slug)
    try:
        db.execute(
            "UPDATE export_jobs SET status='running', started_at=datetime('now') WHERE id=?",
            (job_id,),
        )
        db.commit()
        job = db.execute(
            "SELECT preset_id, burn_captions_json, generate_notes, enhance_speech, "
            "range_start, range_end, spotlight, use_background, moment_banner, "
            "banner_position, vertical_center_spotlight, director_overlays FROM export_jobs WHERE id=?",
            (job_id,),
        ).fetchone()
    finally:
        db.close()
    preset_id = job["preset_id"]
    enhance_speech = bool(job["enhance_speech"])
    job_keys = job.keys()
    range_start = job["range_start"] if "range_start" in job_keys else None
    range_end   = job["range_end"]   if "range_end"   in job_keys else None
    spotlight_flag = bool(job["spotlight"]) if "spotlight" in job_keys else False
    use_background = bool(job["use_background"]) if "use_background" in job_keys else False
    moment_banner = bool(job["moment_banner"]) if "moment_banner" in job_keys else False
    banner_position = job["banner_position"] if "banner_position" in job_keys else "bottom"
    vertical_center_spotlight = bool(job["vertical_center_spotlight"]) if "vertical_center_spotlight" in job_keys else False
    director_overlays_flag = bool(job["director_overlays"]) if "director_overlays" in job_keys else False
    preset = find_preset(preset_id)
    if not preset:
        _update_job(slug, job_id, status="error", error_msg=f"preset desconocido: {preset_id}")
        return

    burn_captions = None
    if job["burn_captions_json"]:
        try:
            burn_captions = json.loads(job["burn_captions_json"])
        except (TypeError, ValueError):
            burn_captions = None

    ext = preset["format"]
    exports_dir = PROJECTS_DIR / slug / "exports"
    exports_dir.mkdir(parents=True, exist_ok=True)
    out_rel = f"{job_id}_{preset_id}.{ext}"
    out_path = exports_dir / out_rel

    try:
        cmd, total_duration = build_ffmpeg_command(
            slug, preset_id, out_path,
            burn_captions=burn_captions,
            enhance_speech=enhance_speech,
            range_start=range_start,
            range_end=range_end,
            spotlight=spotlight_flag,
            use_background=use_background,
            moment_banner=moment_banner,
            banner_position=banner_position or "bottom",
            vertical_center_spotlight=vertical_center_spotlight,
            director_overlays=director_overlays_flag,
        )
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
        notes_rel = None
        if job["generate_notes"]:
            try:
                notes_rel = _write_notes_file(slug, job_id, preset_id, exports_dir)
            except Exception as e:
                # Notes are best-effort — never fail the export over them, but
                # surface the reason in the export log so users can debug.
                with log_path.open("a") as f:
                    f.write(f"\nNOTES GENERATION FAILED: {e}\n")
        db = get_db(slug)
        try:
            db.execute(
                "UPDATE export_jobs SET status='done', progress=100, "
                "finished_at=datetime('now'), output_file=?, notes_file=? WHERE id=?",
                (out_rel, notes_rel, job_id),
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
