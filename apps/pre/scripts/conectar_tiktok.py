"""Guarda en privado la Client key y el Client secret de la app de TikTok de thePod.

Uso (en el servidor):  python3 ~/prepod/scripts/conectar_tiktok.py
Nada de lo que escribas se muestra en pantalla ni queda en el historial.
"""
import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared_config import load_shared_config, update_shared_config  # noqa: E402

key = input("Client key de la app de TikTok: ").strip()
secret = getpass.getpass("Client secret de la app de TikTok (no se ve al escribir): ").strip()
if len(key) < 8 or len(secret) < 16:
    sys.exit("No se guardó: la clave o el secreto parecen incompletos.")
cfg = load_shared_config()
tt = dict(cfg.get("tiktok") or {})
tt.update({"client_key": key, "client_secret": secret})
update_shared_config({"tiktok": tt})
print("Listo. TikTok quedó habilitado en thePod.")
