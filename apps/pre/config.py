import hashlib
from pathlib import Path

from shared_config import load_shared_config


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


BASE_DIR = Path(__file__).resolve().parent
PODCASTS_DIR = BASE_DIR / "podcasts"
UPLOADS_DIR = BASE_DIR / "static" / "uploads"
LANDING_PAGES_DIR = BASE_DIR / "landing_pages"

# Users + policy live in `~/.podpod/users.json`. shared_users re-reads the
# file when its mtime changes, so any UI mutation propagates to all 3 apps
# without needing restarts.
from shared_users import (
    users_passwords as _users_passwords,
    users_profiles as _users_profiles,
    users_policy as _users_policy,
    policy_for as _policy_for,
)


def _live_dict(fn):
    """Tiny wrapper that always returns the latest snapshot on every access."""
    class _D:
        def __getitem__(self, k):     return fn()[k]
        def __contains__(self, k):    return k in fn()
        def get(self, k, default=None): return fn().get(k, default)
        def keys(self):               return fn().keys()
        def values(self):             return fn().values()
        def items(self):              return fn().items()
        def __iter__(self):           return iter(fn())
        def __len__(self):            return len(fn())
    return _D()


USERS         = _live_dict(_users_passwords)
USER_PROFILES = _live_dict(_users_profiles)
USER_POLICY   = _live_dict(_users_policy)


def policy_for(username: str) -> dict:
    return _policy_for(username)

# ----- Shared cross-app config (SSO + webhooks) -----
_shared = load_shared_config()
SECRET_KEY = _shared["secret_key"]
INTEGRATION_SECRET = _shared["integration_secret"]
SESSION_COOKIE_DOMAIN = _shared.get("cookie_domain")

# Image processing
LOGO_MAX_SIZE = (500, 500)
COVER_MAX_SIZE = (1200, 800)

ALLOWED_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
ALLOWED_AUDIO_EXTS = {".mp3", ".wav", ".ogg", ".m4a", ".aac", ".flac", ".webm"}
SOUND_MAX_BYTES = 8 * 1024 * 1024  # 8MB per sound

# Shared sound library (postPod's global pack, also reachable from prePod).
# First existing path wins; falls back to None (library disabled).
_SOUND_LIBRARY_CANDIDATES = [
    Path.home() / "postpod" / "global" / "audio",
    Path.home() / "prodpod" / "static" / "sounds",
]
GLOBAL_SOUNDS_DIR = next((p for p in _SOUND_LIBRARY_CANDIDATES if p.exists()), None)

# Fonts available for branding selection
AVAILABLE_FONTS = [
    # Elegant serifs
    "Fraunces",
    "Playfair Display",
    "DM Serif Display",
    "Lora",
    "Cormorant Garamond",
    "EB Garamond",
    "Libre Baskerville",
    # Modern sans
    "Inter",
    "Poppins",
    "Roboto",
    "Montserrat",
    "Open Sans",
    "Nunito",
    "Nunito Sans",
    "Work Sans",
    "Source Sans 3",
    "Manrope",
    "Plus Jakarta Sans",
    "DM Sans",
    "Outfit",
    "Lexend",
    # Display / character
    "Bricolage Grotesque",
    "Space Grotesk",
    "Archivo",
    "Archivo Black",
    "Bebas Neue",
    "Anton",
    "Oswald",
    "Bangers",
    "Titan One",
    "Permanent Marker",
    # Mono
    "JetBrains Mono",
    "Fira Code",
    "IBM Plex Mono",
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
