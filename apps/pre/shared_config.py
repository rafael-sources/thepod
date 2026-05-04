"""
Shared config loader for the podpod suite (prePod / prodPod / postPod).

All three apps read the same `~/.podpod/config.json` file, so they:
- sign session cookies with the same SECRET_KEY (→ SSO: login in one app
  is recognized by the other two on the same host/domain),
- share the same INTEGRATION_SECRET for server-to-server webhooks,
- know each other's base URLs for cross-app webhooks.
"""

import json
import os
import secrets
from pathlib import Path


SHARED_DIR = Path.home() / ".podpod"
SHARED_FILE = SHARED_DIR / "config.json"


def _default_config():
    return {
        "secret_key": secrets.token_hex(32),
        "integration_secret": secrets.token_hex(32),
        "cookie_domain": None,   # e.g. ".podpod.tudominio.com" in prod
        "prepod_url":  "http://127.0.0.1:5001",
        "postpod_url": "http://127.0.0.1:5000",
        "prodpod_url": "http://127.0.0.1:5002",
    }


def load_shared_config():
    if SHARED_FILE.exists():
        try:
            with SHARED_FILE.open() as f:
                cfg = json.load(f)
            if cfg.get("secret_key") and cfg.get("integration_secret"):
                return cfg
        except (OSError, ValueError):
            pass
    # Bootstrap file with random values the first time any app starts
    SHARED_DIR.mkdir(parents=True, exist_ok=True)
    cfg = _default_config()
    SHARED_FILE.write_text(json.dumps(cfg, indent=2))
    try:
        os.chmod(SHARED_FILE, 0o600)
    except OSError:
        pass
    return cfg


def update_shared_config(patch: dict):
    """Merge `patch` into the shared config file. Returns the updated config."""
    cfg = load_shared_config()
    for k, v in patch.items():
        cfg[k] = v
    SHARED_DIR.mkdir(parents=True, exist_ok=True)
    SHARED_FILE.write_text(json.dumps(cfg, indent=2))
    try:
        os.chmod(SHARED_FILE, 0o600)
    except OSError:
        pass
    return cfg
