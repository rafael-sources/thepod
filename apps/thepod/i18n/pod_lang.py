"""Interface language for the thePod apps (identical copy in each app as pod_lang.py).
The pod_lang cookie is set by the pod-i18n.js switch and shared across the domain; if missing, the browser decides."""
from flask import request


def current_lang() -> str:
    c = request.cookies.get("pod_lang")
    if c in ("es", "en"):
        return c
    return "en" if request.accept_languages.best_match(["es", "en"]) == "en" else "es"
