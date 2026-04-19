"""
Tests for timeline.recalc_relative_moments.

API:
    recalc_relative_moments(moments, old_clips, new_clips) -> list[dict]

    moments:   [{id, type: 'relative'|'absolute', timeline_seconds, label?}]
    old_clips: [{id, duration}] in old timeline order
    new_clips: [{id, duration}] in new timeline order

    Returns: list of updates [{id, timeline_seconds}] ONLY for moments whose
             timeline_seconds actually changed. Absolute moments are never updated.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from timeline import recalc_relative_moments


def _m(id, t, kind="relative"):
    return {"id": id, "type": kind, "timeline_seconds": t, "label": ""}


def _c(id, dur):
    return {"id": id, "duration": dur}


# ---------- Delete ----------

def test_delete_first_clip_shifts_moment_in_next_clip_back():
    # [A(10), B(20)], moment at 15 (inside B at offset 5)
    # After delete A: [B(20)], B now starts at 0, moment should be at 5
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20)]
    moments = [_m(100, 15)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 5}]


def test_delete_clip_moment_inside_moves_to_start_of_next():
    # [A(10), B(20)], moment at 5 (inside A)
    # After delete A: [B(20)], moment should move to start of next surviving clip → 0
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20)]
    moments = [_m(100, 5)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 0}]


def test_delete_last_clip_moment_inside_moves_to_end_of_timeline():
    # [A(10), B(20)], moment at 15 (inside B), delete B
    # New timeline = [A(10)], moment should go to end of timeline = 10
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(1, 10)]
    moments = [_m(100, 15)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 10}]


def test_delete_only_clip_moves_moment_to_zero():
    old = [_c(1, 10)]
    new = []
    moments = [_m(100, 5)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 0}]


def test_absolute_moments_are_never_updated_on_delete():
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20)]
    moments = [_m(100, 5, kind="absolute"), _m(101, 15, kind="absolute")]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == []


# ---------- Insert ----------

def test_insert_clip_shifts_moments_in_clips_after_it():
    # [A(10), C(20)], moment at 15 (inside C at offset 5)
    # Insert B(5) between A and C: [A(10), B(5), C(20)]
    # C now starts at 15, moment should be at 20
    old = [_c(1, 10), _c(3, 20)]
    new = [_c(1, 10), _c(2, 5), _c(3, 20)]
    moments = [_m(100, 15)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 20}]


def test_insert_at_start_shifts_everything():
    # [A(10)], moment at 5 (inside A, offset 5)
    # Insert B(5) at position 0: [B(5), A(10)]
    # A now starts at 5, moment should be at 10
    old = [_c(1, 10)]
    new = [_c(2, 5), _c(1, 10)]
    moments = [_m(100, 5)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 10}]


def test_insert_does_not_affect_moments_before_insertion_point():
    # [A(10), C(20)], moment at 5 (inside A)
    # Insert B(5) between: [A(10), B(5), C(20)]
    # A stays at 0, moment stays at 5
    old = [_c(1, 10), _c(3, 20)]
    new = [_c(1, 10), _c(2, 5), _c(3, 20)]
    moments = [_m(100, 5)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == []


# ---------- Resize ----------

def test_resize_clip_moment_inside_stays_at_same_offset_in_clip():
    # [A(10)], moment at t=5 (offset 5 in A).
    # Resize A to duration 15. Moment stays at t=5 (offset 5 in A).
    old = [_c(1, 10)]
    new = [_c(1, 15)]
    moments = [_m(100, 5)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == []


def test_resize_clip_moment_past_new_end_clamps_to_clip_end():
    # [A(10)], moment at t=8 (offset 8).
    # Resize A to duration 3. Moment at offset 8 is past new end, clamp to 3.
    old = [_c(1, 10)]
    new = [_c(1, 3)]
    moments = [_m(100, 8)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 3}]


def test_resize_clip_shifts_moments_in_later_clips():
    # [A(10), B(20)], moment at 15 (inside B at offset 5).
    # Resize A to 5 (shrink). New timeline [A(5), B(20)], B starts at 5.
    # Moment should be at 10 (B start 5 + offset 5).
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(1, 5), _c(2, 20)]
    moments = [_m(100, 15)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 10}]


# ---------- Reorder ----------

def test_reorder_clips_moves_moment_with_its_clip():
    # [A(10), B(20)], moment at 15 (inside B at offset 5).
    # Reorder to [B(20), A(10)]. B now starts at 0, moment should be at 5.
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20), _c(1, 10)]
    moments = [_m(100, 15)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 5}]


def test_reorder_clips_moment_in_clip_that_moves_later_shifts_forward():
    # [A(10), B(20)], moment at 5 (inside A at offset 5).
    # Reorder to [B(20), A(10)]. A starts at 20, moment should be at 25.
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20), _c(1, 10)]
    moments = [_m(100, 5)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 25}]


# ---------- Invariants ----------

def test_no_change_produces_no_updates():
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(1, 10), _c(2, 20)]
    moments = [_m(100, 5), _m(101, 15, kind="absolute")]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == []


def test_empty_moments_returns_empty():
    old = [_c(1, 10)]
    new = []
    assert recalc_relative_moments([], old, new) == []


def test_mixed_moments_only_relative_updated():
    # [A(10), B(20)], moments: rel@15, abs@15. Delete A.
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20)]
    moments = [_m(100, 15), _m(101, 15, kind="absolute")]
    updates = recalc_relative_moments(moments, old, new)
    # Only the relative one should update (to 5); absolute stays at 15.
    assert updates == [{"id": 100, "timeline_seconds": 5}]


def test_moment_exactly_at_clip_boundary_belongs_to_next_clip():
    # Half-open interval convention: t = clip boundary → belongs to next clip.
    # [A(10), B(20)], moment at exactly 10 (start of B, offset 0 in B).
    # Delete A → B starts at 0, moment should be at 0.
    old = [_c(1, 10), _c(2, 20)]
    new = [_c(2, 20)]
    moments = [_m(100, 10)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 0}]


def test_multiple_surviving_clips_after_delete_gap():
    # [A(10), B(20), C(15)], moment at 15 (inside B at offset 5).
    # Delete B. New timeline [A(10), C(15)]. Moment in deleted B moves to start of C.
    # In new timeline C starts at 10.
    old = [_c(1, 10), _c(2, 20), _c(3, 15)]
    new = [_c(1, 10), _c(3, 15)]
    moments = [_m(100, 15)]
    updates = recalc_relative_moments(moments, old, new)
    assert updates == [{"id": 100, "timeline_seconds": 10}]
