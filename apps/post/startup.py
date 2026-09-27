"""
One-shot maintenance routines run at service startup. All work happens in a
daemon thread so it doesn't block the request handlers.
"""

import sqlite3
import threading
from pathlib import Path

from config import GLOBAL_DIR, PROJECTS_DIR


def _mark_orphaned_caption_jobs():
    """Caption jobs run in daemon threads that die on service restart, leaving
    rows stuck in pending/running forever. Mark them as error so the UI stops
    showing an eternal progress bar."""
    if not PROJECTS_DIR.exists():
        return
    for project_dir in PROJECTS_DIR.iterdir():
        db_path = project_dir / "proyecto.sqlite"
        if not db_path.is_file():
            continue
        try:
            conn = sqlite3.connect(str(db_path), timeout=5)
            conn.execute(
                "UPDATE caption_jobs SET status='error', "
                "error_msg='interrumpido por reinicio del servicio', "
                "finished_at=datetime('now') "
                "WHERE status IN ('pending','running')"
            )
            conn.commit()
            conn.close()
        except sqlite3.Error:
            continue


def _scan_missing_sidecars():
    """Ensure every video has a thumbnail, and every audio/video has waveform peaks."""
    from files import (
        _generate_end_thumbnail, _generate_thumbnail, _generate_waveform,
        _peaks_path, _probe_duration, _thumbnail_end_path, _thumbnail_path,
    )

    def _is_sidecar(name: str) -> bool:
        return (name.endswith(".thumb.jpg")
                or name.endswith(".thumb_end.jpg")
                or name.endswith(".peaks.json"))

    def _process(path: Path, kind: str):
        if not path.is_file() or _is_sidecar(path.name):
            return
        duration = None
        if kind == "video" and not _thumbnail_path(path).exists():
            duration = _probe_duration(path)
            _generate_thumbnail(path, duration)
        if kind == "video" and not _thumbnail_end_path(path).exists():
            if duration is None:
                duration = _probe_duration(path)
            if duration:
                _generate_end_thumbnail(path, duration)
        if kind in ("video", "audio") and not _peaks_path(path).exists():
            if duration is None:
                duration = _probe_duration(path)
            if duration:
                _generate_waveform(path, duration)

    try:
        if PROJECTS_DIR.exists():
            for project_dir in PROJECTS_DIR.iterdir():
                if not project_dir.is_dir():
                    continue
                for kind in ("video", "audio"):
                    d = project_dir / "media" / kind
                    if not d.exists():
                        continue
                    for f in d.iterdir():
                        _process(f, kind)

        for kind in ("video", "audio"):
            gd = GLOBAL_DIR / kind
            if not gd.exists():
                continue
            for f in gd.iterdir():
                _process(f, kind)
    except Exception:
        pass


_started = False
_lock = threading.Lock()


def run_background_maintenance_once():
    """Idempotent: starts the background scan only once per process."""
    global _started
    with _lock:
        if _started:
            return
        _started = True
    # Synchronous and fast (a few UPDATEs): must finish before any new
    # caption job can be created, or we'd mark a live job as orphaned.
    try:
        _mark_orphaned_caption_jobs()
    except Exception:
        pass
    t = threading.Thread(target=_scan_missing_sidecars, daemon=True, name="postpod-sidecar-scan")
    t.start()
