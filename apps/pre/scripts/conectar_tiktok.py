"""Privately stores the Client key and Client secret of thePod's TikTok app.

Usage (on the server):  python3 ~/prepod/scripts/conectar_tiktok.py
Nothing you type is shown on screen or kept in the history.
"""
import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared_config import load_shared_config, update_shared_config  # noqa: E402

key = input("TikTok app Client key: ").strip()
secret = getpass.getpass("TikTok app Client secret (hidden while typing): ").strip()
if len(key) < 8 or len(secret) < 16:
    sys.exit("Not saved: the key or the secret looks incomplete.")
cfg = load_shared_config()
tt = dict(cfg.get("tiktok") or {})
tt.update({"client_key": key, "client_secret": secret})
update_shared_config({"tiktok": tt})
print("Done. TikTok is now enabled in thePod.")
