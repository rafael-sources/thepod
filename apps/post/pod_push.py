"""
Avisos al teléfono (web push) a través de thePod.

Cada app llama a notify(...) y thePod se encarga de mandarlo a los teléfonos donde el usuario
activó los avisos. Es "best effort": si thePod no responde, no pasa nada y no se bloquea la
petición (corre en un hilo, con tiempo máximo de 4 s).
"""
from __future__ import annotations

import json
import threading
import urllib.request

from shared_config import load_shared_config


def _send(usernames, title, body, url, tag):
    cfg = load_shared_config()
    base = (cfg.get("thepod_url") or "").rstrip("/")
    secret = cfg.get("integration_secret") or ""
    if not base or not secret:
        return
    data = json.dumps({"usernames": list(usernames), "title": title, "body": body, "url": url, "tag": tag}).encode()
    req = urllib.request.Request(base + "/api/push/send", data=data, method="POST",
                                 headers={"Content-Type": "application/json", "X-PodPod-Secret": secret})
    try:
        urllib.request.urlopen(req, timeout=4).read()
    except Exception:
        pass


def notify(usernames, title: str, body: str = "", url: str = "/", tag: str | None = None) -> None:
    users = sorted({str(u).strip().lower() for u in (usernames or []) if u})
    if not users:
        return
    threading.Thread(target=_send, args=(users, title, body, url, tag), daemon=True).start()


def project_hosts(slug: str) -> list[str]:
    """Dueño + hosts adicionales de un proyecto (para avisarles)."""
    try:
        from projects import _read_meta, LEGACY_OWNER
        meta = _read_meta(slug) or {}
        return [meta.get("owner_username") or LEGACY_OWNER] + list(meta.get("extra_hosts") or [])
    except Exception:
        return []


def project_name(slug: str) -> str:
    try:
        from projects import _read_meta
        return (_read_meta(slug) or {}).get("name") or slug
    except Exception:
        return slug
