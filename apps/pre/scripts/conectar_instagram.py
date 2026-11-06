"""Privately stores the app ID and secret key of thePod's Instagram app.

Usage (on the server):  python3 ~/prepod/scripts/conectar_instagram.py
Nothing you type is shown on screen or kept in the history.
"""
import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared_config import load_shared_config, update_shared_config  # noqa: E402

app_id = input("Instagram app ID: ").strip()
secret = getpass.getpass("Instagram app secret key (hidden while typing): ").strip()
if not app_id.isdigit() or len(secret) < 16:
    sys.exit("Not saved: the ID must be digits only and the key looks incomplete.")
cfg = load_shared_config()
ig = dict(cfg.get("instagram") or {})
ig.update({"app_id": app_id, "app_secret": secret})
update_shared_config({"instagram": ig})
print("Done. Instagram is now enabled in thePod.")
