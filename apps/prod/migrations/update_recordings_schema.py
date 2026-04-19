"""
Migration: bring the recordings table up to current shape.

1. The original CHECK(track_type IN ('audio','video','mixed_output')) rejects
   the new 'soundboard' track type. Rebuild the table without that CHECK.
2. Add exported_to_postpod_at column used by the postPod auto-export flow.

Idempotent: detects whether the current table already has the right shape and
skips otherwise-unneeded work.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from db import get_db


def _sql_has_check(sql: str) -> bool:
    return sql and "CHECK(track_type" in sql.replace(" ", "").replace("\n", "").replace(" ", "")


def _has_column(db, table: str, col: str) -> bool:
    rows = db.execute(f"PRAGMA table_info({table})").fetchall()
    return any(r["name"] == col for r in rows)


def run():
    db = get_db()
    try:
        sql_row = db.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='recordings'"
        ).fetchone()
        sql = (sql_row["sql"] if sql_row else "") or ""
        has_check = "CHECK" in sql and "track_type" in sql
        needs_col = not _has_column(db, "recordings", "exported_to_postpod_at")

        if not has_check and not needs_col:
            return "ok"

        db.execute("BEGIN")
        if has_check:
            db.execute("ALTER TABLE recordings RENAME TO recordings_old")
            db.execute(
                """
                CREATE TABLE recordings (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id        INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    participant_id    INTEGER REFERENCES participants(id) ON DELETE SET NULL,
                    track_type        TEXT NOT NULL,
                    filename          TEXT NOT NULL,
                    file_path         TEXT NOT NULL,
                    duration_seconds  REAL,
                    size_bytes        INTEGER,
                    mime_type         TEXT,
                    bitrate_kbps      INTEGER,
                    resolution        TEXT,
                    codec             TEXT,
                    exported_to_postpod_at TEXT,
                    created_at        TEXT DEFAULT (datetime('now'))
                )
                """
            )
            db.execute(
                """
                INSERT INTO recordings
                    (id, session_id, participant_id, track_type, filename, file_path,
                     duration_seconds, size_bytes, mime_type, bitrate_kbps, resolution, codec, created_at)
                SELECT
                    id, session_id, participant_id, track_type, filename, file_path,
                    duration_seconds, size_bytes, mime_type, bitrate_kbps, resolution, codec, created_at
                FROM recordings_old
                """
            )
            db.execute("DROP TABLE recordings_old")
            db.execute("CREATE INDEX IF NOT EXISTS idx_recordings_session ON recordings(session_id)")
        elif needs_col:
            db.execute("ALTER TABLE recordings ADD COLUMN exported_to_postpod_at TEXT")

        db.commit()
        return "migrated"
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    print(run())
