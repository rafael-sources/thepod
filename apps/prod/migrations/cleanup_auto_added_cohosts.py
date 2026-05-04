"""
One-shot: prior versions of create_session_endpoint and import_from_prepod
auto-inserted every known operator as a co-host of every new session, even
people unrelated to the podcast. This migration removes those leftover rows.

Heuristic for "auto-added stale co-host":
  role = 'co-host'
  status = 'invited'
  joined_at IS NULL          (never actually connected)
  username IS NOT NULL       (named operator, not a name-only guest)
  username != session.created_by  (not the host themselves)

Idempotent: re-running does nothing once the rows are gone.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from db import get_db


def run():
    db = get_db()
    try:
        rows = db.execute(
            """
            SELECT p.id, p.session_id, p.username, s.created_by
            FROM participants p
            JOIN sessions s ON s.id = p.session_id
            WHERE p.role = 'co-host'
              AND p.status = 'invited'
              AND p.joined_at IS NULL
              AND p.username IS NOT NULL
              AND p.username != s.created_by
            """
        ).fetchall()
        if not rows:
            return "ok-clean"
        ids = [r["id"] for r in rows]
        db.executemany("DELETE FROM participants WHERE id=?", [(i,) for i in ids])
        db.commit()
        return f"removed {len(ids)} stale co-host rows"
    finally:
        db.close()


if __name__ == "__main__":
    print(run())
