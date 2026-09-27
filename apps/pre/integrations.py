"""
Outgoing integrations from prePod to the rest of the suite (postPod / prodPod).

- `GET/PUT /api/integrations/config` — global URLs of the sibling apps.
- `POST /api/podcasts/{slug}/episodes/{id}/send-to-postpod` — serializes
  the episode and posts it to postPod's receive-webhook endpoint. Returns
  the newly-created postPod project's slug.
- `GET /api/podcasts/{slug}/episodes/{id}/integration-status` — asks
  postPod if a project with this episode's shared_project_id exists.
"""

import urllib.error
import urllib.request
import json as _json

from flask import Blueprint, jsonify, request

from auth import require_auth
from config import INTEGRATION_SECRET, PODCASTS_DIR
from db import get_db
from shared_config import load_shared_config, update_shared_config


bp = Blueprint("integrations", __name__)


def _ensure_podcast(slug):
    if not (PODCASTS_DIR / slug).exists():
        from flask import abort
        abort(404, description="podcast no encontrado")


def _http_json(method: str, url: str, body=None, headers=None, timeout=10):
    """Minimal JSON HTTP client using stdlib. Returns (status, data)."""
    data_bytes = None
    hdrs = {"Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    if body is not None:
        data_bytes = _json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data_bytes, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode(errors="replace")
            try:
                return resp.status, _json.loads(raw) if raw else None
            except ValueError:
                return resp.status, {"raw": raw[:500]}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace") if e.fp else ""
        try:
            return e.code, _json.loads(raw) if raw else None
        except ValueError:
            return e.code, {"error": raw[:300] or str(e)}
    except urllib.error.URLError as e:
        raise RuntimeError(f"conexión fallida: {e.reason}")
    except TimeoutError:
        raise RuntimeError("tiempo de espera agotado")


# ---------------------------------------------------------------------------
# Config: URLs of sibling apps
# ---------------------------------------------------------------------------

def _public_config():
    cfg = load_shared_config()
    return {
        "postpod_url": cfg.get("postpod_url") or "",
        "prodpod_url": cfg.get("prodpod_url") or "",
        "cookie_domain": cfg.get("cookie_domain"),
    }


@bp.get("/api/integrations/config")
@require_auth
def get_integration_config():
    return jsonify(_public_config())


@bp.put("/api/integrations/config")
@require_auth
def update_integration_config():
    data = request.get_json(silent=True) or {}
    patch = {}
    for k in ("postpod_url", "prodpod_url", "cookie_domain"):
        if k in data:
            val = data[k]
            if val is not None and isinstance(val, str):
                val = val.strip() or None
            patch[k] = val
    if not patch:
        return jsonify({"error": "nada para actualizar"}), 400
    update_shared_config(patch)
    return jsonify(_public_config())


@bp.get("/api/integrations/ping")
@require_auth
def ping_siblings():
    """Quick connectivity check for both sibling apps."""
    cfg = load_shared_config()
    out = {}
    for name, url in (("postpod", cfg.get("postpod_url")), ("prodpod", cfg.get("prodpod_url"))):
        if not url:
            out[name] = {"configured": False}
            continue
        try:
            status, _data = _http_json(
                "GET",
                f"{url.rstrip('/')}/api/integrations/status?shared_project_id=__ping__",
                headers={"X-PodPod-Secret": INTEGRATION_SECRET},
                timeout=3,
            )
            # 400/404 are "reachable" (endpoint present). 401 = secret mismatch. 2xx = strange but reachable.
            reachable = status in (200, 400, 404)
            out[name] = {
                "configured": True,
                "url": url,
                "reachable": reachable,
                "status_code": status,
                "secret_mismatch": status == 401,
            }
        except RuntimeError as e:
            out[name] = {"configured": True, "url": url, "reachable": False, "error": str(e)}
    return jsonify(out)


# ---------------------------------------------------------------------------
# Episode → postPod
# ---------------------------------------------------------------------------

def _serialize_episode_payload(slug: str, ep_id: int):
    db = get_db(slug)
    try:
        podcast = db.execute("SELECT * FROM podcast_meta WHERE slug=?", (slug,)).fetchone()
        if not podcast:
            return None, ("podcast no encontrado", 404)
        ep = db.execute("SELECT * FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return None, ("episodio no encontrado", 404)

        script_rows = db.execute(
            "SELECT speaker, content, estimated_duration, notes, position "
            "FROM script_sections WHERE episode_id=? ORDER BY position, id",
            (ep_id,),
        ).fetchall()
        idea_rows = db.execute(
            "SELECT content, author, status, votes "
            "FROM ideas WHERE episode_id=? ORDER BY votes DESC, created_at",
            (ep_id,),
        ).fetchall()
        link_rows = db.execute(
            "SELECT platform, url FROM episode_links WHERE episode_id=?",
            (ep_id,),
        ).fetchall()
        guest_rows = db.execute(
            "SELECT id, name, email, role, bio, rsvp_token, "
            "social_instagram, social_twitter, social_youtube, social_tiktok, photo_filename "
            "FROM episode_guests WHERE episode_id=?",
            (ep_id,),
        ).fetchall()
        block_rows = db.execute(
            "SELECT eb.id, eb.position, eb.kind, eb.title, eb.duration_estimate, eb.notes, "
            "eb.sponsor_id, eb.planned_offset_seconds, "
            "s.name AS sponsor_name, s.copy AS sponsor_copy, "
            "s.url AS sponsor_url, s.logo_filename AS sponsor_logo "
            "FROM episode_blocks eb "
            "LEFT JOIN sponsors s ON s.id = eb.sponsor_id "
            "WHERE eb.episode_id=? ORDER BY eb.position, eb.id",
            (ep_id,),
        ).fetchall()
        sponsor_rows = db.execute(
            "SELECT id, name, copy, url, logo_filename FROM sponsors WHERE is_active=1 ORDER BY position, id"
        ).fetchall()
        sound_rows = db.execute(
            "SELECT id, name, filename, shortcut_key, color, duration_seconds, file_size_bytes, position "
            "FROM podcast_sounds ORDER BY position, id"
        ).fetchall()

        landing = db.execute(
            "SELECT social_instagram, social_tiktok, social_twitter, social_youtube "
            "FROM landing_config LIMIT 1"
        ).fetchone()

        base = request.host_url.rstrip("/")
        branding = {
            "color_primary": podcast["color_primary"],
            "color_secondary": podcast["color_secondary"],
            "color_accent": podcast["color_accent"],
            "font_heading": podcast["font_heading"],
            "font_body": podcast["font_body"],
            "logo_url": (f"{base}/media/podcasts/{slug}/branding/{podcast['logo_filename']}"
                        if podcast["logo_filename"] else None),
            "cover_url": (f"{base}/media/podcasts/{slug}/branding/{podcast['cover_filename']}"
                        if podcast["cover_filename"] else None),
            "background_url": (f"{base}/media/podcasts/{slug}/branding/{podcast['background_filename']}"
                        if "background_filename" in podcast.keys() and podcast["background_filename"] else None),
            "social_instagram": (landing["social_instagram"] if landing else None),
            "social_tiktok": (landing["social_tiktok"] if landing else None),
            "social_twitter": (landing["social_twitter"] if landing else None),
            "social_youtube": (landing["social_youtube"] if landing else None),
        }

        sounds = []
        for s in sound_rows:
            d = dict(s)
            d["download_url"] = f"{base}/media/podcasts/{slug}/sounds/{s['filename']}"
            sounds.append(d)

        # Owner + extra_hosts: travels with the payload so prodPod / postPod
        # know who is allowed to host this episode.
        owner_username = podcast["owner_username"] if "owner_username" in podcast.keys() else None
        owner_username = owner_username or "admin"
        extra_hosts = []
        if "extra_hosts" in podcast.keys() and podcast["extra_hosts"]:
            try:
                v = _json.loads(podcast["extra_hosts"])
                if isinstance(v, list):
                    extra_hosts = [str(x) for x in v]
            except (TypeError, ValueError):
                pass

        payload = {
            "source_app": "prepod",
            "source_url": request.host_url.rstrip("/"),
            "shared_project_id": podcast["shared_project_id"],
            "owner_username": owner_username,
            "extra_hosts": extra_hosts,
            "podcast": {
                "name": podcast["name"],
                "slug": podcast["slug"],
                "description": podcast["description"] or "",
                "tagline": podcast["tagline"] or "",
                "branding": branding,
                "sounds": sounds,
                "owner_username": owner_username,
                "extra_hosts": extra_hosts,
            },
            "episode": {
                "id": ep["id"],
                "number": ep["episode_number"],
                "title": ep["title"],
                "description": ep["description"] or "",
                "status": ep["status"],
                "scheduled_date": ep["scheduled_date"],
                "duration_estimate": ep["duration_estimate"],
                "script": [dict(r) for r in script_rows],
                "ideas": [dict(r) for r in idea_rows],
                "links": [dict(r) for r in link_rows],
                "guests": [{**dict(r),
                            "rsvp_url": f"{base}/rsvp/{r['rsvp_token']}" if r["rsvp_token"] else None,
                            "photo_url": (f"{base}/media/podcasts/{slug}/guests/{r['photo_filename']}"
                                          if r["photo_filename"] else None)} for r in guest_rows],
                "blocks": [{**dict(r), "sponsor_logo_url": (f"{base}/media/podcasts/{slug}/sponsors/{r['sponsor_logo']}" if r["sponsor_logo"] else None)} for r in block_rows],
                "sponsors": [{**dict(r), "logo_url": (f"{base}/media/podcasts/{slug}/sponsors/{r['logo_filename']}" if r["logo_filename"] else None)} for r in sponsor_rows],
            },
        }
        return payload, None
    finally:
        db.close()


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/send-to-postpod")
@require_auth
def send_to_postpod(slug, ep_id):
    _ensure_podcast(slug)
    cfg = load_shared_config()
    url = (cfg.get("postpod_url") or "").rstrip("/")
    if not url:
        return jsonify({"error": "postPod URL no configurada"}), 400

    payload, err = _serialize_episode_payload(slug, ep_id)
    if err:
        msg, code = err
        return jsonify({"error": msg}), code

    try:
        status, data = _http_json(
            "POST",
            f"{url}/api/integrations/prepod/import",
            body=payload,
            headers={"X-PodPod-Secret": INTEGRATION_SECRET},
            timeout=15,
        )
    except RuntimeError as e:
        return jsonify({"error": f"no pude contactar postPod: {e}"}), 502

    if status in (200, 201) and data and data.get("project"):
        project = data["project"]
        return jsonify({
            "ok": True,
            "created": bool(data.get("created")),
            "postpod_slug": project.get("slug"),
            "postpod_url": f"{url}/#/projects/{project.get('slug')}",
        })
    return jsonify({"error": (data or {}).get("error") or f"postPod respondió {status}"}), 502


@bp.post("/api/podcasts/<slug>/episodes/<int:ep_id>/send-to-prodpod")
@require_auth
def send_to_prodpod(slug, ep_id):
    _ensure_podcast(slug)
    cfg = load_shared_config()
    url = (cfg.get("prodpod_url") or "").rstrip("/")
    if not url:
        return jsonify({"error": "prodPod URL no configurada"}), 400

    payload, err = _serialize_episode_payload(slug, ep_id)
    if err:
        msg, code = err
        return jsonify({"error": msg}), code

    try:
        status, data = _http_json(
            "POST",
            f"{url}/api/integrations/prepod/import",
            body=payload,
            headers={"X-PodPod-Secret": INTEGRATION_SECRET},
            timeout=15,
        )
    except RuntimeError as e:
        return jsonify({"error": f"no pude contactar prodPod: {e}"}), 502

    if status in (200, 201) and data and data.get("project"):
        project = data["project"]

        # Persist any invite URLs that prodPod returned per guest, keyed by
        # the (case-insensitive) guest name we sent in the payload.
        invites = data.get("guest_invites") or []
        if invites:
            db = get_db(slug)
            try:
                for inv in invites:
                    name = (inv.get("name") or "").strip()
                    iurl = (inv.get("invite_url") or "").strip()
                    itok = (inv.get("invite_token") or "").strip()
                    if not name or not iurl:
                        continue
                    db.execute(
                        "UPDATE episode_guests SET invite_url=?, invite_token=? "
                        "WHERE episode_id=? AND LOWER(name)=LOWER(?)",
                        (iurl, itok, ep_id, name),
                    )
                db.commit()
            finally:
                db.close()

        return jsonify({
            "ok": True,
            "created": bool(data.get("created")),
            "prodpod_session_id": project.get("id"),
            "prodpod_url": f"{url}/",
            "guest_invites": invites,
        })
    return jsonify({"error": (data or {}).get("error") or f"prodPod respondió {status}"}), 502


@bp.get("/api/podcasts/<slug>/episodes/<int:ep_id>/integration-status")
@require_auth
def episode_integration_status(slug, ep_id):
    _ensure_podcast(slug)
    cfg = load_shared_config()
    db = get_db(slug)
    try:
        podcast = db.execute(
            "SELECT shared_project_id FROM podcast_meta WHERE slug=?", (slug,)
        ).fetchone()
        if not podcast:
            return jsonify({"error": "podcast no encontrado"}), 404
        spid = podcast["shared_project_id"]
    finally:
        db.close()

    if not spid:
        return jsonify({"linked": False})

    result = {"shared_project_id": spid, "postpod": None, "prodpod": None}

    for name, base in (("postpod", cfg.get("postpod_url")), ("prodpod", cfg.get("prodpod_url"))):
        if not base:
            continue
        try:
            status, data = _http_json(
                "GET",
                f"{base.rstrip('/')}/api/integrations/status?shared_project_id={spid}&source_episode_id={ep_id}",
                headers={"X-PodPod-Secret": INTEGRATION_SECRET},
                timeout=3,
            )
            if status == 200 and data:
                result[name] = {
                    "linked": True,
                    "project": data.get("project"),
                    "url": base.rstrip("/"),
                }
            else:
                result[name] = {"linked": False}
        except RuntimeError:
            result[name] = {"linked": False, "unreachable": True}

    return jsonify(result)


# ---------------------------------------------------------------------------
# Inbound: prodPod lifecycle events (recording started/stopped, exports)
# ---------------------------------------------------------------------------

def _require_shared_secret_inbound():
    got = (request.headers.get("X-PodPod-Secret")
           or request.headers.get("Authorization", "").removeprefix("Bearer ").strip())
    if got != INTEGRATION_SECRET:
        return jsonify({"error": "no autorizado"}), 401
    return None


_EVENT_TO_STATUS = {
    "recording_started": "recording",
    "recording_stopped": "recorded",
    "exported_to_postpod": "exported",
}


@bp.post("/api/integrations/prodpod/event")
def prodpod_event():
    err = _require_shared_secret_inbound()
    if err:
        return err
    data = request.get_json(silent=True) or {}
    event = (data.get("event") or "").strip()
    slug = (data.get("slug") or "").strip()
    ep_id = data.get("episode_id")
    if not event or not slug or not ep_id:
        return jsonify({"error": "event, slug, episode_id requeridos"}), 400
    if event not in _EVENT_TO_STATUS:
        return jsonify({"error": f"event desconocido: {event}"}), 400
    if not (PODCASTS_DIR / slug).exists():
        return jsonify({"error": "podcast no encontrado"}), 404

    status = _EVENT_TO_STATUS[event]
    meta = {
        "session_id": data.get("session_id"),
        "shared_project_id": data.get("shared_project_id"),
        "occurred_at": data.get("occurred_at"),
    }
    for k in ("started_at", "finished_at", "exported_count", "failed_count",
              "postpod_project_slug", "postpod_url"):
        if k in data:
            meta[k] = data[k]

    db = get_db(slug)
    try:
        ep = db.execute("SELECT id FROM episodes WHERE id=?", (ep_id,)).fetchone()
        if not ep:
            return jsonify({"error": "episodio no encontrado"}), 404
        db.execute(
            "UPDATE episodes SET production_status=?, production_meta=?, "
            "production_updated_at=datetime('now') WHERE id=?",
            (status, _json.dumps(meta), ep_id),
        )
        db.commit()
    finally:
        db.close()

    return jsonify({"ok": True, "production_status": status})


# ---------------------------------------------------------------------------
# Export file browser — proxy to postPod
# ---------------------------------------------------------------------------

def _get_postpod_spid(slug):
    """Return (postpod_base_url, shared_project_id) or abort."""
    cfg = load_shared_config()
    base = (cfg.get("postpod_url") or "").rstrip("/")
    if not base:
        return None, None
    db = get_db(slug)
    try:
        row = db.execute(
            "SELECT shared_project_id FROM podcast_meta WHERE slug=?", (slug,)
        ).fetchone()
    finally:
        db.close()
    if not row or not row["shared_project_id"]:
        return None, None
    return base, row["shared_project_id"]


@bp.get("/api/podcasts/<slug>/exports")
@require_auth
def list_podcast_exports(slug):
    _ensure_podcast(slug)
    base, spid = _get_postpod_spid(slug)
    if not base or not spid:
        return jsonify([])
    try:
        status, data = _http_json(
            "GET",
            f"{base}/api/integrations/exports?shared_project_id={spid}",
            headers={"X-PodPod-Secret": INTEGRATION_SECRET},
            timeout=8,
        )
        if status == 200 and isinstance(data, list):
            return jsonify(data)
        return jsonify([])
    except RuntimeError:
        return jsonify([])


@bp.delete("/api/podcasts/<slug>/exports/<int:job_id>")
@require_auth
def delete_podcast_export(slug, job_id):
    _ensure_podcast(slug)
    base, spid = _get_postpod_spid(slug)
    if not base or not spid:
        return jsonify({"error": "postPod no vinculado"}), 400
    try:
        status, data = _http_json(
            "DELETE",
            f"{base}/api/integrations/exports/{job_id}?shared_project_id={spid}",
            headers={"X-PodPod-Secret": INTEGRATION_SECRET},
            timeout=8,
        )
        if status == 200:
            return jsonify(data or {"ok": True})
        return jsonify(data or {"error": "error de postPod"}), status
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 502


@bp.get("/api/podcasts/<slug>/exports/<int:job_id>/download")
@require_auth
def download_podcast_export(slug, job_id):
    from flask import Response
    _ensure_podcast(slug)
    base, spid = _get_postpod_spid(slug)
    if not base or not spid:
        return jsonify({"error": "postPod no vinculado"}), 400
    url = f"{base}/api/integrations/exports/{job_id}/download?shared_project_id={spid}"
    hdrs = {"X-PodPod-Secret": INTEGRATION_SECRET, "Accept": "*/*"}
    req = urllib.request.Request(url, headers=hdrs, method="GET")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        ct = resp.headers.get("Content-Type", "application/octet-stream")
        cd = resp.headers.get("Content-Disposition", "")
        def generate():
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                yield chunk
        return Response(generate(), content_type=ct, headers={"Content-Disposition": cd} if cd else {})
    except urllib.error.HTTPError as e:
        return jsonify({"error": f"postPod respondió {e.code}"}), e.code
    except (urllib.error.URLError, TimeoutError):
        return jsonify({"error": "no se pudo conectar con postPod"}), 502
