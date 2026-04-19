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
        }

        payload = {
            "source_app": "prepod",
            "shared_project_id": podcast["shared_project_id"],
            "podcast": {
                "name": podcast["name"],
                "slug": podcast["slug"],
                "description": podcast["description"] or "",
                "tagline": podcast["tagline"] or "",
                "branding": branding,
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
        return jsonify({
            "ok": True,
            "created": bool(data.get("created")),
            "prodpod_session_id": project.get("id"),
            "prodpod_url": f"{url}/",
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
                f"{base.rstrip('/')}/api/integrations/status?shared_project_id={spid}",
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
