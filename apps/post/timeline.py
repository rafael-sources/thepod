"""
Non-destructive timeline utilities.

The timeline is an ordered sequence of clips; each clip has an `id` and a
`duration` (effective duration in the timeline).

Moments are labeled timestamps on the timeline, of two kinds:
  - 'relative': its `timeline_seconds` is recomputed when clips are
                added/removed/resized/reordered, so that the moment follows
                the clip it was originally anchored to.
  - 'absolute': its `timeline_seconds` is fixed and never adjusted by this
                module.

`recalc_relative_moments` is a pure function that, given a list of moments and
the old + new clip orderings, returns the subset of moments whose
`timeline_seconds` needs to change.
"""

from typing import Iterable

EPS = 1e-9


def _clip_start_positions(clips):
    """Return {clip_id: timeline_start_seconds} and total duration."""
    starts = {}
    t = 0.0
    for c in clips:
        starts[c["id"]] = t
        t += c["duration"]
    return starts, t


def _locate(t, clips):
    """
    Given a timeline second `t` and a list of clips in order, return
    `(clip_id, offset_in_clip)` where offset_in_clip is `t - clip_start`.

    Uses a half-open interval convention: a moment exactly at the boundary
    between clip A and clip B belongs to B (offset 0 in B).

    Returns `(None, t - total_duration)` if `t` is past the last clip.
    """
    cursor = 0.0
    for c in clips:
        end = cursor + c["duration"]
        if cursor <= t < end:
            return c["id"], t - cursor
        cursor = end
    # past the end (or exactly at the end, which we treat as "past")
    return None, t - cursor


def recalc_relative_moments(moments, old_clips, new_clips):
    """
    Compute which relative moments need their `timeline_seconds` updated
    after the timeline clip list has changed from `old_clips` to `new_clips`.

    Returns a list of `{"id": ..., "timeline_seconds": ...}` entries, ONLY for
    moments that actually moved. Absolute moments are never included.

    Rules:
      - If the clip the moment was anchored to still exists: the moment
        stays at the same offset inside that clip (clamped to the clip's
        new duration if the clip got shorter).
      - If the clip was removed: the moment moves to the start of the next
        surviving clip in the old order. If no such clip exists, the moment
        goes to the end of the new timeline.
      - Moments that were past the end of the old timeline are placed at
        the end of the new timeline.
    """
    new_starts, new_total = _clip_start_positions(new_clips)
    new_by_id = {c["id"]: c for c in new_clips}
    old_order = [c["id"] for c in old_clips]
    old_index = {cid: i for i, cid in enumerate(old_order)}

    updates = []

    for m in moments:
        if m.get("type") != "relative":
            continue

        t_old = m["timeline_seconds"]
        clip_id, offset = _locate(t_old, old_clips)

        if clip_id is not None and clip_id in new_by_id:
            # Anchor clip survived: keep offset, clamp to new duration.
            new_dur = new_by_id[clip_id]["duration"]
            new_t = new_starts[clip_id] + min(offset, new_dur)
        elif clip_id is not None:
            # Anchor clip was removed: find next surviving clip in OLD order.
            idx = old_index[clip_id]
            new_t = new_total
            for j in range(idx + 1, len(old_order)):
                nxt = old_order[j]
                if nxt in new_starts:
                    new_t = new_starts[nxt]
                    break
        else:
            # Moment was past the end of the old timeline.
            new_t = new_total

        if abs(new_t - t_old) > EPS:
            updates.append({"id": m["id"], "timeline_seconds": new_t})

    return updates
