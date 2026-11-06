"""Guarda en privado el ID y la clave secreta de la app de Instagram de thePod.

Uso (en el servidor):  python3 ~/prepod/scripts/conectar_instagram.py
Nada de lo que escribas se muestra en pantalla ni queda en el historial.
"""
import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared_config import load_shared_config, update_shared_config  # noqa: E402

app_id = input("ID de la app de Instagram: ").strip()
secret = getpass.getpass("Clave secreta de la app de Instagram (no se ve al escribir): ").strip()
if not app_id.isdigit() or len(secret) < 16:
    sys.exit("No se guardó: el ID debe ser solo números y la clave parece incompleta.")
cfg = load_shared_config()
ig = dict(cfg.get("instagram") or {})
ig.update({"app_id": app_id, "app_secret": secret})
update_shared_config({"instagram": ig})
print("Listo. Instagram quedó habilitado en thePod.")
