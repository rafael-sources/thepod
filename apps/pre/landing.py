"""
Landing page generator: config, episode links, team members, and public
endpoints (`/landing/{slug}` and `/landing/{slug}/feed.xml`).

The public endpoints are intentionally NOT protected — they're meant to be
hit by anyone (listeners, podcast apps, social previews).
"""

import json
import uuid
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.etree import ElementTree as ET

from flask import Blueprint, Response, abort, jsonify, render_template, request
from PIL import Image

from auth import require_auth
from config import ALLOWED_IMAGE_EXTS, PODCASTS_DIR
from db import get_db


bp = Blueprint("landing", __name__)


TEAM_IMAGE_MAX = (400, 400)

# Platforms presented in the UI. Storage accepts any string (e.g. "podbean")
KNOWN_PLATFORMS = [
    "youtube", "spotify", "apple_podcasts", "podbean",
    "google_podcasts", "overcast", "castbox", "iheart", "website",
]


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        abort(404, description="podcast no encontrado")


_YT_RE = __import__("re").compile(
    r"(?:youtube\.com/(?:watch\?v=|embed/|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{6,})"
)


def _enrich_link(link: dict):
    """Add `kind` / `thumb_url` / `embed_url` to a link entry, if recognizable."""
    url = (link.get("url") or "").strip()
    m = _YT_RE.search(url)
    if m:
        vid = m.group(1)
        link["kind"] = "youtube"
        link["video_id"] = vid
        # maxresdefault sometimes 404s for older videos; hqdefault is universal.
        link["thumb_url"] = f"https://img.youtube.com/vi/{vid}/hqdefault.jpg"
    else:
        link["kind"] = (link.get("platform") or "external").lower()


def _podcast_meta(db):
    return db.execute("SELECT * FROM podcast_meta").fetchone()


def _render_blocks(json_str: str) -> str:
    """Convert Editor.js block JSON into HTML for the landing template.
    Returns empty string if there are no blocks."""
    if not json_str:
        return ""
    try:
        import json as _json, html as _html
        data = _json.loads(json_str)
        blocks = data.get("blocks") or []
    except (TypeError, ValueError):
        return ""
    if not blocks:
        return ""

    out = []
    for b in blocks:
        kind = b.get("type")
        d = b.get("data") or {}
        # Per-block alignment from the alignment tune (if present).
        tunes = b.get("tunes") or {}
        align = (tunes.get("anyTuneName") or {}).get("alignment") if isinstance(tunes, dict) else None
        align_attr = f' style="text-align:{align}"' if align in ("left","center","right","justify") else ""
        if kind == "header":
            level = max(1, min(int(d.get("level") or 2), 6))
            txt = d.get("text") or ""
            out.append(f"<h{level} class='ej-header'{align_attr}>{txt}</h{level}>")
        elif kind == "paragraph":
            txt = d.get("text") or ""
            out.append(f"<p class='ej-paragraph'{align_attr}>{txt}</p>")
        elif kind == "list":
            items = d.get("items") or []
            tag = "ol" if d.get("style") == "ordered" else "ul"
            lis = "".join(f"<li>{i}</li>" for i in items)
            out.append(f"<{tag} class='ej-list'{align_attr}>{lis}</{tag}>")
        elif kind == "quote":
            t = d.get("text") or ""
            cap = d.get("caption") or ""
            out.append(
                f"<blockquote class='ej-quote'{align_attr}>"
                f"<p>{t}</p>"
                + (f"<cite>{_html.escape(cap)}</cite>" if cap else "")
                + "</blockquote>"
            )
        elif kind == "delimiter":
            out.append("<hr class='ej-delimiter'>")
        elif kind == "image":
            url = ((d.get("file") or {}).get("url")) or ""
            cap = d.get("caption") or ""
            classes = ["ej-image"]
            if d.get("withBackground"): classes.append("ej-image--bg")
            if d.get("withBorder"):     classes.append("ej-image--border")
            if d.get("stretched"):      classes.append("ej-image--stretched")
            cls = " ".join(classes)
            if url:
                out.append(
                    f"<figure class='{cls}'{align_attr}>"
                    f"<img src='{_html.escape(url)}' alt='{_html.escape(cap)}' loading='lazy'>"
                    + (f"<figcaption>{_html.escape(cap)}</figcaption>" if cap else "")
                    + "</figure>"
                )
        elif kind == "embed":
            embed = d.get("embed") or d.get("source") or ""
            if embed:
                out.append(
                    f"<div class='ej-embed'{align_attr}>"
                    f"<iframe src='{_html.escape(embed)}' frameborder='0' allowfullscreen></iframe>"
                    + (f"<figcaption>{_html.escape(d.get('caption') or '')}</figcaption>" if d.get("caption") else "")
                    + "</div>"
                )
    return "\n".join(out)


def _get_or_create_landing(db):
    row = db.execute("SELECT * FROM landing_config LIMIT 1").fetchone()
    if row:
        return row
    db.execute("INSERT INTO landing_config (template) VALUES ('minimal')")
    db.commit()
    return db.execute("SELECT * FROM landing_config LIMIT 1").fetchone()


def _serialize_landing(row):
    if not row:
        return None
    return {
        "template": row["template"],
        "custom_css": row["custom_css"] or "",
        "show_episodes": bool(row["show_episodes"]),
        "show_team": bool(row["show_team"]),
        "owner_name": row["owner_name"] or "",
        "owner_email": row["owner_email"] or "",
        "language": row["language"] or "es",
        "social_youtube": row["social_youtube"] or "",
        "social_spotify": row["social_spotify"] or "",
        "social_apple_podcasts": row["social_apple_podcasts"] or "",
        "social_instagram": row["social_instagram"] or "",
        "social_tiktok": row["social_tiktok"] or "",
        "social_twitter": row["social_twitter"] or "",
        "analytics_code": row["analytics_code"] or "",
        "og_image_url": row["og_image_url"] or "",
        "updated_at": row["updated_at"],
    }


# ---------------------------------------------------------------------------
# Landing config CRUD
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/landing")
@require_auth
def get_landing(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = _get_or_create_landing(db)
        return jsonify(_serialize_landing(row))
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/landing")
@require_auth
def update_landing(slug):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    allowed = {
        "template", "custom_css",
        "show_episodes", "show_team",
        "owner_name", "owner_email", "language",
        "social_youtube", "social_spotify", "social_apple_podcasts",
        "social_instagram", "social_tiktok", "social_twitter",
        "analytics_code", "og_image_url",
    }
    updates = {k: v for k, v in data.items() if k in allowed}

    # Normalize booleans
    for bkey in ("show_episodes", "show_team"):
        if bkey in updates:
            updates[bkey] = 1 if updates[bkey] else 0

    if "template" in updates and updates["template"] not in ("minimal", "bold", "classic"):
        return jsonify({"error": f"template inválido: {updates['template']}"}), 400

    if not updates:
        return jsonify({"error": "nada para actualizar"}), 400

    db = get_db(slug)
    try:
        _get_or_create_landing(db)
        cols = ", ".join(f"{k}=?" for k in updates) + ", updated_at=datetime('now')"
        params = list(updates.values())
        db.execute(f"UPDATE landing_config SET {cols}", params)
        db.commit()
        row = _get_or_create_landing(db)
        return jsonify(_serialize_landing(row))
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Episode links
# ---------------------------------------------------------------------------

@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/links")
@require_auth
def list_links(slug, ep_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT id, platform, url FROM episode_links WHERE episode_id=? ORDER BY platform",
            (ep_id,),
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/links")
@require_auth
def upsert_link(slug, ep_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    platform = (data.get("platform") or "").strip().lower()
    url = (data.get("url") or "").strip()
    if not platform or not url:
        return jsonify({"error": "platform y url requeridos"}), 400
    db = get_db(slug)
    try:
        if not db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone():
            return jsonify({"error": "episodio no encontrado"}), 404
        # Upsert
        existing = db.execute(
            "SELECT id FROM episode_links WHERE episode_id=? AND platform=?",
            (ep_id, platform),
        ).fetchone()
        if existing:
            db.execute(
                "UPDATE episode_links SET url=? WHERE id=?",
                (url, existing["id"]),
            )
            link_id = existing["id"]
        else:
            cur = db.execute(
                "INSERT INTO episode_links (episode_id, platform, url) VALUES (?, ?, ?)",
                (ep_id, platform, url),
            )
            link_id = cur.lastrowid
        db.commit()
        return jsonify({"id": link_id, "platform": platform, "url": url}), 201
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/episodes/<int:ep_id>/links/<platform>")
@require_auth
def delete_link(slug, ep_id, platform):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        db.execute(
            "DELETE FROM episode_links WHERE episode_id=? AND platform=?",
            (ep_id, platform.lower()),
        )
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Team members
# ---------------------------------------------------------------------------

def _team_image_url(slug, filename):
    return f"/media/podcasts/{slug}/branding/{filename}" if filename else None


def _serialize_member(slug, row):
    keys = row.keys()
    return {
        "id": row["id"],
        "name": row["name"],
        "role": row["role"] or "",
        "bio": row["bio"] or "",
        "image_filename": row["image_filename"],
        "image_url": _team_image_url(slug, row["image_filename"]),
        "social_twitter": row["social_twitter"] or "",
        "social_instagram": row["social_instagram"] or "",
        "social_website": row["social_website"] or "",
        "social_youtube": row["social_youtube"] if "social_youtube" in keys else "",
        "social_tiktok": row["social_tiktok"] if "social_tiktok" in keys else "",
        "position": row["position"],
    }


@bp.get("/api/podcasts/<slug>/team")
@require_auth
def list_team(slug):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        rows = db.execute(
            "SELECT * FROM team_members ORDER BY position, id"
        ).fetchall()
        return jsonify([_serialize_member(slug, r) for r in rows])
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/team")
@require_auth
def create_member(slug):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name requerido"}), 400
    db = get_db(slug)
    try:
        n = db.execute("SELECT COUNT(*) AS n FROM team_members").fetchone()["n"]
        cur = db.execute(
            "INSERT INTO team_members (name, role, bio, position) VALUES (?, ?, ?, ?)",
            (name, data.get("role") or "", data.get("bio") or "", n),
        )
        db.commit()
        row = db.execute("SELECT * FROM team_members WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_member(slug, row)), 201
    finally:
        db.close()


@bp.put("/api/podcasts/<slug>/team/<int:member_id>")
@require_auth
def update_member(slug, member_id):
    _ensure_podcast(slug)
    data = request.get_json(silent=True) or {}
    allowed = {"name", "role", "bio", "social_twitter", "social_instagram", "social_website", "social_youtube", "social_tiktok", "position"}
    updates = {k: v for k, v in data.items() if k in allowed}
    if not updates:
        return jsonify({"error": "nada para actualizar"}), 400
    db = get_db(slug)
    try:
        if not db.execute("SELECT id FROM team_members WHERE id=?", (member_id,)).fetchone():
            return jsonify({"error": "miembro no encontrado"}), 404
        cols = ", ".join(f"{k}=?" for k in updates)
        params = list(updates.values()) + [member_id]
        db.execute(f"UPDATE team_members SET {cols} WHERE id=?", params)
        db.commit()
        row = db.execute("SELECT * FROM team_members WHERE id=?", (member_id,)).fetchone()
        return jsonify(_serialize_member(slug, row))
    finally:
        db.close()


@bp.delete("/api/podcasts/<slug>/team/<int:member_id>")
@require_auth
def delete_member(slug, member_id):
    _ensure_podcast(slug)
    db = get_db(slug)
    try:
        row = db.execute("SELECT image_filename FROM team_members WHERE id=?", (member_id,)).fetchone()
        if not row:
            return jsonify({"error": "miembro no encontrado"}), 404
        if row["image_filename"]:
            img = PODCASTS_DIR / slug / "branding" / row["image_filename"]
            if img.exists():
                try: img.unlink()
                except OSError: pass
        db.execute("DELETE FROM team_members WHERE id=?", (member_id,))
        db.commit()
        return jsonify({"ok": True})
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/team/<int:member_id>/image")
@require_auth
def upload_member_image(slug, member_id):
    _ensure_podcast(slug)
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "archivo requerido"}), 400
    ext = Path(f.filename).suffix.lower()
    if ext not in ALLOWED_IMAGE_EXTS:
        return jsonify({"error": f"extensión no soportada: {ext}"}), 400

    db = get_db(slug)
    try:
        row = db.execute("SELECT image_filename FROM team_members WHERE id=?", (member_id,)).fetchone()
        if not row:
            return jsonify({"error": "miembro no encontrado"}), 404

        dest_dir = PODCASTS_DIR / slug / "branding"
        dest_dir.mkdir(parents=True, exist_ok=True)
        filename = f"member_{member_id}_{uuid.uuid4().hex[:6]}{ext}"
        dest = dest_dir / filename

        # Resize + save
        from io import BytesIO
        img = Image.open(BytesIO(f.read()))
        img.load()
        if ext in (".jpg", ".jpeg") and img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1] if img.mode in ("RGBA", "LA") else None)
            img = bg
        img.thumbnail(TEAM_IMAGE_MAX, Image.LANCZOS)
        if ext in (".jpg", ".jpeg"):
            img.save(dest, "JPEG", quality=88, optimize=True)
        elif ext == ".webp":
            img.save(dest, "WEBP", quality=88)
        else:
            img.save(dest, "PNG", optimize=True)

        # Remove previous
        if row["image_filename"]:
            old = dest_dir / row["image_filename"]
            if old.exists() and old != dest:
                try: old.unlink()
                except OSError: pass

        db.execute("UPDATE team_members SET image_filename=? WHERE id=?", (filename, member_id))
        db.commit()
        return jsonify({"filename": filename, "url": _team_image_url(slug, filename)})
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Public landing page + RSS
# ---------------------------------------------------------------------------

def _safe_absolute_url(base_url: str, path_or_url: str) -> str:
    if not path_or_url:
        return ""
    if path_or_url.startswith(("http://", "https://")):
        return path_or_url
    if path_or_url.startswith("/"):
        return base_url.rstrip("/") + path_or_url
    return f"{base_url.rstrip('/')}/{path_or_url}"


def _load_landing_bundle(slug):
    """Read everything the public pages need from the project's SQLite."""
    db = get_db(slug)
    try:
        podcast = _podcast_meta(db)
        if not podcast:
            return None
        landing = _get_or_create_landing(db)
        # Manual landing order: explicit landing_position wins (lower first).
        # Episodes without a position fall back to the date/created sort.
        episodes_rows = db.execute("""
            SELECT * FROM episodes
            ORDER BY
              CASE WHEN landing_position IS NULL THEN 1 ELSE 0 END,
              landing_position ASC,
              COALESCE(scheduled_date, '') DESC,
              created_at DESC,
              id DESC
            LIMIT 50
        """).fetchall()

        episode_ids = [e["id"] for e in episodes_rows]
        links_by_ep = {e: [] for e in episode_ids}
        if episode_ids:
            placeholders = ",".join("?" * len(episode_ids))
            link_rows = db.execute(
                f"SELECT episode_id, platform, url FROM episode_links WHERE episode_id IN ({placeholders})",
                episode_ids,
            ).fetchall()
            for r in link_rows:
                links_by_ep[r["episode_id"]].append({"platform": r["platform"], "url": r["url"]})

        team_rows = db.execute(
            "SELECT * FROM team_members ORDER BY position, id"
        ).fetchall()

        # Annotate links with embed/thumbnail info so the templates can show
        # a YouTube/Spotify-style card instead of a plain text link.
        for ep_id, links in links_by_ep.items():
            for l in links:
                _enrich_link(l)

        return {
            "podcast": dict(podcast),
            "landing": dict(landing),
            "episodes": [
                {**dict(e), "links": links_by_ep.get(e["id"], [])}
                for e in episodes_rows
            ],
            "team": [dict(t) for t in team_rows],
        }
    finally:
        db.close()


def _build_social_list(landing):
    """Return list of {platform, url, label} entries for the social bar."""
    out = []
    mapping = [
        ("youtube", "YouTube"),
        ("spotify", "Spotify"),
        ("apple_podcasts", "Apple Podcasts"),
        ("instagram", "Instagram"),
        ("tiktok", "TikTok"),
        ("twitter", "Twitter / X"),
    ]
    for key, label in mapping:
        url = (landing.get(f"social_{key}") or "").strip()
        if url:
            out.append({"platform": key, "label": label, "url": url})
    return out


def _logo_url(slug, podcast):
    if podcast.get("logo_filename"):
        return f"/media/podcasts/{slug}/branding/{podcast['logo_filename']}"
    return None


def _cover_url(slug, podcast):
    if podcast.get("cover_filename"):
        return f"/media/podcasts/{slug}/branding/{podcast['cover_filename']}"
    return None


@bp.get("/landing/<slug>")
def render_landing(slug):
    bundle = _load_landing_bundle(slug)
    if not bundle:
        abort(404)
    podcast = bundle["podcast"]
    landing = bundle["landing"]
    socials = _build_social_list(landing)

    ctx = {
        "slug": slug,
        "podcast": podcast,
        "landing": landing,
        "episodes": bundle["episodes"] if landing.get("show_episodes") else [],
        "team": bundle["team"] if landing.get("show_team") else [],
        "socials": socials,
        "logo_url": _logo_url(slug, podcast),
        "cover_url": _cover_url(slug, podcast),
        "rss_url": (
            (podcast["rss_override_url"] if "rss_override_url" in podcast.keys() and podcast["rss_override_url"] else "").strip()
            or f"/landing/{slug}/feed.xml"
        ),
        "edit_mode": request.args.get("edit_mode") == "1",
        "blocks_html": _render_blocks(
            bundle["podcast"].get("landing_blocks") if isinstance(bundle["podcast"], dict)
            else (bundle["podcast"]["landing_blocks"] if "landing_blocks" in bundle["podcast"].keys() else None)
        ),
    }
    template = landing.get("template") or "minimal"
    if template not in ("minimal", "bold", "classic"):
        template = "minimal"
    return render_template(f"landing/{template}.html", **ctx)


@bp.get("/landing/<slug>/feed.xml")
def render_rss(slug):
    bundle = _load_landing_bundle(slug)
    if not bundle:
        abort(404)
    podcast = bundle["podcast"]
    landing = bundle["landing"]
    base = request.host_url.rstrip("/")
    rss_ns = {"itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd"}
    ET.register_namespace("itunes", rss_ns["itunes"])

    rss = ET.Element("rss", attrib={"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = podcast["name"]
    ET.SubElement(channel, "link").text = f"{base}/landing/{slug}"
    ET.SubElement(channel, "description").text = podcast.get("description") or podcast.get("tagline") or ""
    ET.SubElement(channel, "language").text = (landing.get("language") or "es")

    image_url = _cover_url(slug, podcast) or _logo_url(slug, podcast)
    if image_url:
        img = ET.SubElement(channel, "image")
        ET.SubElement(img, "url").text = _safe_absolute_url(base, image_url)
        ET.SubElement(img, "title").text = podcast["name"]
        ET.SubElement(img, "link").text = f"{base}/landing/{slug}"
        itunes_img = ET.SubElement(channel, "{%s}image" % rss_ns["itunes"])
        itunes_img.set("href", _safe_absolute_url(base, image_url))

    owner = ET.SubElement(channel, "{%s}owner" % rss_ns["itunes"])
    ET.SubElement(owner, "{%s}name" % rss_ns["itunes"]).text = landing.get("owner_name") or ""
    ET.SubElement(owner, "{%s}email" % rss_ns["itunes"]).text = landing.get("owner_email") or ""
    ET.SubElement(channel, "{%s}explicit" % rss_ns["itunes"]).text = "no"
    if landing.get("owner_name"):
        ET.SubElement(channel, "{%s}author" % rss_ns["itunes"]).text = landing["owner_name"]

    for ep in bundle["episodes"]:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = ep.get("title") or f"Episodio {ep.get('episode_number')}"
        # Use AI summary + highlights as description if available
        description = ""
        ai_summary = ep.get("ai_summary") if isinstance(ep, dict) else (ep["ai_summary"] if "ai_summary" in ep.keys() else None)
        ai_highlights = None
        raw_highlights = ep.get("ai_highlights") if isinstance(ep, dict) else (ep["ai_highlights"] if "ai_highlights" in ep.keys() else None)
        if raw_highlights:
            try:
                ai_highlights = json.loads(raw_highlights) if isinstance(raw_highlights, str) else raw_highlights
            except (json.JSONDecodeError, TypeError):
                ai_highlights = None

        if ai_summary:
            description = ai_summary
            if ai_highlights:
                description += "\n\nPuntos clave:\n" + "\n".join(f"• {h}" for h in ai_highlights)
        else:
            description = ep.get("description") or ""
        ET.SubElement(item, "description").text = description
        ET.SubElement(item, "link").text = f"{base}/landing/{slug}#ep{ep['id']}"
        ET.SubElement(item, "guid", attrib={"isPermaLink": "false"}).text = f"{podcast.get('shared_project_id','')}:{ep['id']}"

        pub_date = ep.get("scheduled_date") or (ep.get("created_at") or "")
        try:
            if pub_date:
                # Parse either "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS"
                dt = None
                for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
                    try:
                        dt = datetime.strptime(pub_date.strip(), fmt)
                        break
                    except ValueError:
                        continue
                if dt:
                    dt = dt.replace(tzinfo=timezone.utc)
                    ET.SubElement(item, "pubDate").text = format_datetime(dt)
        except Exception:
            pass

        dur = ep.get("duration_estimate")
        if dur and dur > 0:
            mm = int(dur)
            ET.SubElement(item, "{%s}duration" % rss_ns["itunes"]).text = f"{mm:02d}:00"
        ET.SubElement(item, "{%s}explicit" % rss_ns["itunes"]).text = "no"

        # Enclosure: prefer media_url (VPS), fall back to first external link
        media_url = ep.get("media_url") if isinstance(ep, dict) else (ep["media_url"] if "media_url" in ep.keys() else None)
        if media_url:
            ext = media_url.rsplit(".", 1)[-1].lower() if "." in media_url else "mp3"
            mime = "video/mp4" if ext in ("mp4", "webm", "mov") else "audio/mpeg"
            ET.SubElement(item, "enclosure", attrib={
                "url": media_url,
                "type": mime,
                "length": "0",
            })
        else:
            ext_links = [l for l in ep.get("links", []) if l["url"].startswith(("http://", "https://"))]
            if ext_links:
                ET.SubElement(item, "enclosure", attrib={
                    "url": ext_links[0]["url"],
                    "type": "audio/mpeg",
                    "length": "0",
                })

    xml = b'<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(rss, encoding="utf-8")
    return Response(xml, mimetype="application/rss+xml; charset=utf-8")
