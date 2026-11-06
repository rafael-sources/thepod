"""Idioma de la interfaz para las apps de thePod (copia idéntica en cada app como pod_lang.py).
La cookie pod_lang la pone el switch de pod-i18n.js y la comparte el dominio; si no está, decide el navegador."""
from flask import request


def current_lang() -> str:
    c = request.cookies.get("pod_lang")
    if c in ("es", "en"):
        return c
    return "en" if request.accept_languages.best_match(["es", "en"]) == "en" else "es"
