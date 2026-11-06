"""
Media hosting via VPS: upload files over SSH/rsync,
return public URLs for RSS enclosures.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from shared_config import load_shared_config


def _get_hosting_config() -> dict | None:
    """Return hosting config dict or None if not configured."""
    cfg = load_shared_config()
    hosting = cfg.get("hosting")
    if not hosting or not hosting.get("host"):
        return None
    return hosting


def _build_remote_path(podcast_slug: str, filename: str) -> str:
    """Build the remote filesystem path for an uploaded file."""
    cfg = _get_hosting_config()
    base_path = (cfg or {}).get("upload_path", "/var/www/media/podcasts/")
    return f"{base_path.rstrip('/')}/{podcast_slug}/{filename}"


def _build_public_url(cfg: dict, podcast_slug: str, filename: str) -> str:
    """Build the public URL for an uploaded file."""
    base_url = cfg["base_url"].rstrip("/")
    return f"{base_url}/{podcast_slug}/{filename}"


def upload_file(podcast_slug: str, local_path: str | Path, filename: str) -> dict:
    """Upload a file to VPS via rsync over SSH.

    Returns: {"ok": True, "url": "https://..."} or {"ok": False, "error": "..."}
    """
    cfg = _get_hosting_config()
    if not cfg:
        return {"ok": False, "error": "Hosting no configurado en ~/.podpod/config.json"}

    local_path = Path(local_path)
    if not local_path.is_file():
        return {"ok": False, "error": f"Archivo no encontrado: {local_path}"}

    remote_dir = f"{cfg['upload_path'].rstrip('/')}/{podcast_slug}/"
    ssh_key = os.path.expanduser(cfg.get("ssh_key", "~/.ssh/id_contabo"))
    ssh_opts = f"ssh -i {ssh_key} -o StrictHostKeyChecking=accept-new"
    remote_target = f"{cfg['user']}@{cfg['host']}:{remote_dir}"

    # Ensure remote directory exists
    mkdir_cmd = [
        "ssh", "-i", ssh_key, "-o", "StrictHostKeyChecking=accept-new",
        f"{cfg['user']}@{cfg['host']}",
        f"mkdir -p {remote_dir}",
    ]
    try:
        subprocess.run(mkdir_cmd, check=True, capture_output=True, timeout=15)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "error": f"No se pudo crear directorio remoto: {e}"}

    # Upload via rsync
    rsync_cmd = [
        "rsync", "-az", "--progress",
        "-e", ssh_opts,
        str(local_path),
        remote_target,
    ]
    try:
        subprocess.run(rsync_cmd, check=True, capture_output=True, timeout=600)
    except subprocess.CalledProcessError as e:
        return {"ok": False, "error": f"rsync falló: {e.stderr.decode()[:200]}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Upload timeout (10 min)"}

    url = _build_public_url(cfg, podcast_slug, filename)
    return {"ok": True, "url": url}
