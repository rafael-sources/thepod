"""
Distribution panel — manage podcast platform connections (Spotify, Apple, YouTube).

Endpoints:
    GET  /api/podcasts/<slug>/distribution          — list platform statuses
    POST /api/podcasts/<slug>/distribution          — add/update a platform
    POST /api/podcasts/<slug>/distribution/validate — validate RSS feed readiness
    DELETE /api/podcasts/<slug>/distribution/<platform> — remove a platform
"""

import json

from flask import Blueprint, abort, jsonify, request

from auth import require_auth
from config import PODCASTS_DIR
from db import get_db

bp = Blueprint("distribution", __name__)

PLATFORMS = {
    "spotify": {
        "name": "Spotify",
        "submit_url": "https://podcasters.spotify.com/pod/dashboard/add-podcast",
        "help": "Entra con tu cuenta personal de Spotify, selecciona 'Add your podcast' y pega la URL del feed RSS.",
    },
    "apple": {
        "name": "Apple Podcasts",
        "submit_url": "https://podcastsconnect.apple.com",
        "help": "Inicia sesión con tu Apple ID personal, haz clic en '+' y pega la URL del feed RSS.",
    },
    "youtube": {
        "name": "YouTube",
        "submit_url": None,
        "help": "YouTube requiere subir el video directamente. Usa el botón 'Publicar' en cada episodio para subir automáticamente.",
    },
}


def _ensure_distribution_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS distribution_platforms (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            platform    TEXT NOT NULL UNIQUE
                        CHECK(platform IN ('spotify', 'apple', 'youtube')),
            status      TEXT NOT NULL DEFAULT 'not_configured'
                        CHECK(status IN ('not_configured', 'pending', 'connected')),
            external_url TEXT,
            submitted_at TEXT,
            connected_at TEXT,
            notes       TEXT,
            created_at  TEXT DEFAULT (datetime('now')),
            updated_at  TEXT DEFAULT (datetime('now'))
        )
    """)
    conn.commit()


def _serialize_platform(row) -> dict:
    return {
        "id": row["id"],
        "platform": row["platform"],
        "status": row["status"],
        "external_url": row["external_url"],
        "submitted_at": row["submitted_at"],
        "connected_at": row["connected_at"],
        "notes": row["notes"],
    }


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


def _get_feed_url(slug: str) -> str:
    from shared_config import load_shared_config
    cfg = load_shared_config()
    prepod_url = cfg.get("prepod_url", "")
    if prepod_url:
        return f"{prepod_url}/landing/{slug}/feed.xml"
    return f"/landing/{slug}/feed.xml"


def _validate_feed_requirements(slug: str) -> dict:
    """Check that the podcast feed meets platform requirements."""
    issues = []
    warnings = []

    db = get_db(slug)
    try:
        _ensure_distribution_table(db)
        podcast = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not podcast:
            return {"valid": False, "issues": ["Podcast no encontrado"], "warnings": []}

        if not podcast["name"] or not podcast["name"].strip():
            issues.append("El podcast necesita un nombre")

        if not podcast["description"] or len(podcast["description"].strip()) < 10:
            issues.append("El podcast necesita una descripción (mínimo 10 caracteres)")

        if not podcast["cover_filename"]:
            issues.append("Se requiere una imagen de portada (artwork) — mínimo 1400x1400px, idealmente 3000x3000px")

        landing = db.execute("SELECT * FROM landing_config LIMIT 1").fetchone()
        if landing:
            if not landing["owner_name"]:
                issues.append("Configura el nombre del propietario en la Landing")
            if not landing["owner_email"]:
                warnings.append("Se recomienda configurar el email del propietario")

        episode_count = db.execute(
            "SELECT COUNT(*) as c FROM episodes WHERE status IN ('recorded', 'published')"
        ).fetchone()["c"]
        if episode_count == 0:
            issues.append("Se necesita al menos 1 episodio publicado o grabado")

        published_with_media = db.execute(
            "SELECT COUNT(*) as c FROM episodes WHERE media_url IS NOT NULL AND media_url != ''"
        ).fetchone()["c"]
        if episode_count > 0 and published_with_media == 0:
            warnings.append("Ningún episodio tiene archivo de media subido — las plataformas requieren un enclosure válido")

    finally:
        db.close()

    return {
        "valid": len(issues) == 0,
        "issues": issues,
        "warnings": warnings,
        "feed_url": _get_feed_url(slug),
    }


@bp.get("/api/podcasts/<slug>/distribution")
@require_auth
def get_distribution(slug):
    """Return all platform statuses + feed URL + validation summary."""
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        _ensure_distribution_table(db)
        rows = db.execute("SELECT * FROM distribution_platforms ORDER BY platform").fetchall()
    finally:
        db.close()

    platforms_data = {p: {"platform": p, "status": "not_configured", **PLATFORMS[p]} for p in PLATFORMS}
    for row in rows:
        platforms_data[row["platform"]] = {**PLATFORMS.get(row["platform"], {}), **_serialize_platform(row)}

    validation = _validate_feed_requirements(slug)

    return jsonify({
        "platforms": platforms_data,
        "feed_url": _get_feed_url(slug),
        "validation": validation,
    })


@bp.post("/api/podcasts/<slug>/distribution")
@require_auth
def update_platform(slug):
    """Add or update a platform connection."""
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    platform = data.get("platform", "").strip().lower()
    if platform not in PLATFORMS:
        return jsonify({"error": f"Plataforma no válida: {platform}"}), 400

    status = data.get("status", "pending")
    if status not in ("not_configured", "pending", "connected"):
        return jsonify({"error": "Estado no válido"}), 400

    db = get_db(slug)
    try:
        _ensure_distribution_table(db)
        existing = db.execute(
            "SELECT id FROM distribution_platforms WHERE platform=?", (platform,)
        ).fetchone()

        if existing:
            fields = ["status=?", "updated_at=datetime('now')"]
            values = [status]
            if data.get("external_url"):
                fields.append("external_url=?")
                values.append(data["external_url"])
            if status == "pending" and not data.get("submitted_at"):
                fields.append("submitted_at=datetime('now')")
            elif data.get("submitted_at"):
                fields.append("submitted_at=?")
                values.append(data["submitted_at"])
            if status == "connected":
                fields.append("connected_at=datetime('now')")
            if data.get("notes") is not None:
                fields.append("notes=?")
                values.append(data["notes"])
            values.append(existing["id"])
            db.execute(f"UPDATE distribution_platforms SET {', '.join(fields)} WHERE id=?", values)
        else:
            db.execute(
                """INSERT INTO distribution_platforms (platform, status, external_url, submitted_at, notes)
                   VALUES (?, ?, ?, CASE WHEN ?='pending' THEN datetime('now') ELSE NULL END, ?)""",
                (platform, status, data.get("external_url"), status, data.get("notes")),
            )
        db.commit()

        row = db.execute("SELECT * FROM distribution_platforms WHERE platform=?", (platform,)).fetchone()
    finally:
        db.close()

    return jsonify(_serialize_platform(row))


@bp.post("/api/podcasts/<slug>/distribution/validate")
@require_auth
def validate_feed(slug):
    """Validate RSS feed readiness for platform submission."""
    _ensure_podcast(slug)
    return jsonify(_validate_feed_requirements(slug))


@bp.delete("/api/podcasts/<slug>/distribution/<platform>")
@require_auth
def remove_platform(slug, platform):
    """Reset a platform connection."""
    _ensure_podcast(slug)
    if platform not in PLATFORMS:
        return jsonify({"error": "Plataforma no válida"}), 400

    db = get_db(slug)
    try:
        _ensure_distribution_table(db)
        db.execute("DELETE FROM distribution_platforms WHERE platform=?", (platform,))
        db.commit()
    finally:
        db.close()

    return jsonify({"ok": True})


@bp.post("/api/podcasts/<slug>/distribution/check")
@require_auth
def check_platform_live(slug):
    """Check if a podcast is live on a platform (searches public catalogs)."""
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    platform = data.get("platform", "").strip().lower()

    if platform not in ("spotify", "apple"):
        return jsonify({"error": "Solo se puede verificar Spotify y Apple Podcasts"}), 400

    db = get_db(slug)
    try:
        podcast = db.execute("SELECT name FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
    finally:
        db.close()

    if not podcast:
        return jsonify({"found": False})

    podcast_name = podcast["name"]
    found = False
    external_url = None

    try:
        import urllib.request
        import urllib.parse

        if platform == "apple":
            search_url = (
                "https://itunes.apple.com/search?"
                + urllib.parse.urlencode({"term": podcast_name, "media": "podcast", "limit": "5"})
            )
            req = urllib.request.Request(search_url, headers={"User-Agent": "prePod/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                results = json.loads(resp.read())
                for r in results.get("results", []):
                    if r.get("collectionName", "").lower().strip() == podcast_name.lower().strip():
                        found = True
                        external_url = r.get("collectionViewUrl")
                        break

        elif platform == "spotify":
            pass

    except Exception:
        pass

    if found:
        db = get_db(slug)
        try:
            _ensure_distribution_table(db)
            db.execute(
                """UPDATE distribution_platforms
                   SET status='connected', connected_at=datetime('now'), external_url=?
                   WHERE platform=?""",
                (external_url, platform),
            )
            db.commit()
        finally:
            db.close()

    return jsonify({"found": found, "external_url": external_url})
