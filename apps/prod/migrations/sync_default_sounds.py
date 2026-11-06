"""
Migration: re-sync sound_effects for every session so they match the current
DEFAULT_SOUNDS list. Run once at app startup; idempotent.

Strategy: for each session, delete all rows where is_default=1 and re-insert
the current default pack. Custom (user-uploaded) sounds with is_default=0 are
left alone, but since we're re-inserting defaults with the same keys, any
non-default with the same shortcut_key gets orphaned — which is fine.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config import DEFAULT_SOUNDS
from db import get_db


def run():
    db = get_db()
    try:
        sessions = db.execute("SELECT id FROM sessions").fetchall()
        total = 0
        for s in sessions:
            sid = s["id"]
            # Remove defaults
            db.execute("DELETE FROM sound_effects WHERE session_id=? AND is_default=1", (sid,))
            # Re-insert
            for snd in DEFAULT_SOUNDS:
                db.execute(
                    "INSERT INTO sound_effects (session_id, name, filename, shortcut_key, color, is_default) "
                    "VALUES (?, ?, ?, ?, ?, 1)",
                    (sid, snd["name"], snd["filename"], snd["key"], snd["color"]),
                )
            total += 1
        db.commit()
        return total
    finally:
        db.close()


if __name__ == "__main__":
    n = run()
    print(f"synced defaults for {n} session(s)")
