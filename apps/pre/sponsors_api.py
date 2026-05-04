"""
Sponsors / ad-read management.

A sponsor is a podcast-level entity (copy + URL + notes) — it lives once
and is referenced from any rundown block whose `kind='sponsor'` via the
`episode_blocks.sponsor_id` foreign key. The report endpoint walks that
join to count and list episodes that ran a given sponsor.

All endpoints scoped under `/api/podcasts/<slug>/`.
"""

import csv
import io
import re

from flask import Blueprint, Response, abort, jsonify, request

from auth import require_auth
from config import PODCASTS_DIR
from db import get_db


bp = Blueprint("sponsors_api", __name__)


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _serialize_sponsor(row, episode_count: int | None = None):
    out = {
        "id": row["id"],
        "name": row["name"],
        "copy": row["copy"] or "",
        "url": row["url"] or "",
        "notes": row["notes"] or "",
        "is_active": bool(row["is_active"]),
        "position": row["position"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }
    if episode_count is not None:
        out["episode_count"] = episode_count
    return out


@bp.get("/api/podcasts/<slug>/sponsors")
@require_auth
def list_sponsors(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM sponsors ORDER BY position, name COLLATE NOCASE"
        ).fetchall()
        out = []
        for r in rows:
            n = db.execute(
                "SELECT COUNT(DISTINCT episode_id) AS n "
                "FROM episode_blocks WHERE sponsor_id=?",
                (r["id"],),
            ).fetchone()["n"]
            out.append(_serialize_sponsor(r, n))
        return jsonify(out)
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/sponsors")
@require_auth
def create_sponsor(slug):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name requerido"}), 400
    db = get_db(slug)
    try:
        max_pos = db.execute(
            "SELECT COALESCE(MAX(position), -1) AS m FROM sponsors"
        ).fetchone()["m"]
        cur = db.execute(
            "INSERT INTO sponsors (name, copy, url, notes, is_active, position) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                name,
                (data.get("copy") or "").strip(),
                (data.get("url") or "").strip() or None,
                (data.get("notes") or "").strip() or None,
                1 if data.get("is_active", True) else 0,
                max_pos + 1,
            ),
        )
        db.commit()
        row = db.execute("SELECT * FROM sponsors WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_sponsor(row, 0)), 201
    finally:
        db.close()


@bp.patch("/api/podcasts/<slug>/sponsors/<int:sid>")
@require_auth
def update_sponsor(slug, sid):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    db = get_db(slug)
    try:
        existing = db.execute("SELECT * FROM sponsors WHERE id=?", (sid,)).fetchone()
        if not existing:
            return jsonify({"error": "sponsor no encontrado"}), 404
        updates, params = [], []
        if "name" in data:
            n = (data["name"] or "").strip()
            if not n:
                return jsonify({"error": "name no puede estar vacío"}), 400
            updates.append("name=?"); params.append(n)
        for f in ("copy", "url", "notes"):
            if f in data:
                v = (data[f] or "").strip()
                if f != "copy":
                    v = v or None
                updates.append(f"{f}=?"); params.append(v)
        if "is_active" in data:
            updates.append("is_active=?"); params.append(1 if data["is_active"] else 0)
        if not updates:
            return jsonify({"error": "nada para actualizar"}), 400
        params.append(sid)
        db.execute(
            f"UPDATE sponsors SET {', '.join(updates)}, updated_at=datetime('now') WHERE id=?",
            params,
        )
        db.commit()
        row = db.execute("SELECT * FROM sponsors WHERE id=?", (sid,)).fetchone()
        return jsonify(_serialize_sponsor(row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/sponsors/<int:sid>")
@require_auth
def delete_sponsor(slug, sid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        if not db.execute("SELECT id FROM sponsors WHERE id=?", (sid,)).fetchone():
            return jsonify({"error": "sponsor no encontrado"}), 404
        # ON DELETE SET NULL on episode_blocks.sponsor_id (declared in db.py).
        db.execute("DELETE FROM sponsors WHERE id=?", (sid,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Linking: attach an existing sponsor to a rundown block (kind=sponsor).
# ---------------------------------------------------------------------------

@bp.put("/api/podcasts/<slug>/blocks/<int:block_id>/sponsor")
@require_auth
def set_block_sponsor(slug, block_id):
    """Body: {sponsor_id: int|null}. Pass null to unlink."""
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    sponsor_id = data.get("sponsor_id")
    if sponsor_id is not None:
        try:
            sponsor_id = int(sponsor_id)
        except (TypeError, ValueError):
            return jsonify({"error": "sponsor_id inválido"}), 400

    db = get_db(slug)
    try:
        blk = db.execute(
            "SELECT id, kind FROM episode_blocks WHERE id=?", (block_id,)
        ).fetchone()
        if not blk:
            return jsonify({"error": "bloque no encontrado"}), 404
        if sponsor_id is not None:
            sp = db.execute(
                "SELECT id FROM sponsors WHERE id=?", (sponsor_id,)
            ).fetchone()
            if not sp:
                return jsonify({"error": "sponsor no encontrado"}), 404
        db.execute(
            "UPDATE episode_blocks SET sponsor_id=? WHERE id=?",
            (sponsor_id, block_id),
        )
        db.commit()
        return jsonify({"ok": True, "sponsor_id": sponsor_id})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Report: which episodes ran a given sponsor, with totals.
# ---------------------------------------------------------------------------

def _safe_filename(s: str, fallback: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]+", "_", s or "").strip("_")
    return safe or fallback


def _report_data(db, sid: int):
    sponsor = db.execute("SELECT * FROM sponsors WHERE id=?", (sid,)).fetchone()
    if not sponsor:
        return None
    rows = db.execute(
        """
        SELECT e.id AS episode_id, e.episode_number, e.title, e.status,
               e.scheduled_date, e.scheduled_at,
               b.id AS block_id, b.title AS block_title, b.duration_estimate
        FROM episode_blocks b
        JOIN episodes e ON e.id = b.episode_id
        WHERE b.sponsor_id = ?
        ORDER BY COALESCE(e.scheduled_at, e.scheduled_date) DESC, e.id DESC
        """,
        (sid,),
    ).fetchall()
    total_blocks = len(rows)
    total_minutes = sum(float(r["duration_estimate"] or 0) for r in rows)
    distinct_episodes = len({r["episode_id"] for r in rows})
    return {
        "sponsor": {
            "id": sponsor["id"],
            "name": sponsor["name"],
            "copy": sponsor["copy"] or "",
            "url": sponsor["url"] or "",
            "is_active": bool(sponsor["is_active"]),
        },
        "totals": {
            "episodes": distinct_episodes,
            "blocks": total_blocks,
            "duration_minutes_estimated": round(total_minutes, 2),
        },
        "episodes": [
            {
                "episode_id": r["episode_id"],
                "episode_number": r["episode_number"],
                "title": r["title"],
                "status": r["status"],
                "scheduled_date": r["scheduled_date"],
                "scheduled_at": r["scheduled_at"],
                "block_id": r["block_id"],
                "block_title": r["block_title"] or "",
                "duration_estimate_min": r["duration_estimate"],
            }
            for r in rows
        ],
    }


@bp.get("/api/podcasts/<slug>/sponsors/<int:sid>/report")
@require_auth
def sponsor_report(slug, sid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        data = _report_data(db, sid)
    finally:
        db.close()
    if data is None:
        return jsonify({"error": "sponsor no encontrado"}), 404
    return jsonify(data)


@bp.get("/api/podcasts/<slug>/sponsors/<int:sid>/report.csv")
@require_auth
def sponsor_report_csv(slug, sid):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        data = _report_data(db, sid)
    finally:
        db.close()
    if data is None:
        return ("sponsor no encontrado", 404)

    buf = io.StringIO()
    w = csv.writer(buf)
    sp = data["sponsor"]
    tot = data["totals"]
    w.writerow(["Sponsor", sp["name"]])
    if sp["url"]:
        w.writerow(["URL", sp["url"]])
    w.writerow(["Episodios totales", tot["episodes"]])
    w.writerow(["Bloques totales", tot["blocks"]])
    w.writerow(["Duración estimada (min)", tot["duration_minutes_estimated"]])
    w.writerow([])
    w.writerow(["episode_number", "title", "status", "scheduled", "block_title", "duration_min"])
    for ep in data["episodes"]:
        when = ep["scheduled_at"] or ep["scheduled_date"] or ""
        w.writerow([
            ep["episode_number"], ep["title"], ep["status"], when,
            ep["block_title"], ep["duration_estimate_min"] or "",
        ])
    fname = _safe_filename(sp["name"], f"sponsor-{sid}") + "-report.csv"
    return Response(
        buf.getvalue(),
        mimetype="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
