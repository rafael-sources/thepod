import hashlib
from pathlib import Path

from shared_config import load_shared_config


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


BASE_DIR = Path(__file__).resolve().parent
PODCASTS_DIR = BASE_DIR / "podcasts"
UPLOADS_DIR = BASE_DIR / "static" / "uploads"
LANDING_PAGES_DIR = BASE_DIR / "landing_pages"

USERS = {
    "admin":  md5("CAMBIAR-EN-PRIMER-ARRANQUE"),
    "rafael": md5("CAMBIAR-EN-PRIMER-ARRANQUE"),
}

# ----- Shared cross-app config (SSO + webhooks) -----
_shared = load_shared_config()
SECRET_KEY = _shared["secret_key"]
INTEGRATION_SECRET = _shared["integration_secret"]
SESSION_COOKIE_DOMAIN = _shared.get("cookie_domain")

# Image processing
LOGO_MAX_SIZE = (500, 500)
COVER_MAX_SIZE = (1200, 800)

ALLOWED_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}

# Fonts available for branding selection
AVAILABLE_FONTS = [
    "Fraunces",
    "Bricolage Grotesque",
    "Inter",
    "Poppins",
    "Roboto",
    "Lora",
    "Playfair Display",
    "Space Grotesk",
    "DM Serif Display",
    "Archivo",
]

# Default brand colors on podcast creation (prePod blue family)
DEFAULT_COLORS = {
    "primary":   "#5a8bff",
    "secondary": "#1e2a54",
    "accent":    "#f4c770",
}

# Integration — webhook URLs saved per project in future plans
POSTPOD_DEFAULT_URL = "http://127.0.0.1:5000"
PRODPOD_DEFAULT_URL = "http://127.0.0.1:5002"
