import hashlib
from pathlib import Path

from shared_config import load_shared_config


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


BASE_DIR = Path(__file__).resolve().parent
SESSIONS_DIR = BASE_DIR / "sessions"
SOUNDS_DIR = BASE_DIR / "static" / "sounds"

USERS = {
    "admin":  md5("CAMBIAR-EN-PRIMER-ARRANQUE"),
    "rafael": md5("CAMBIAR-EN-PRIMER-ARRANQUE"),
}

USER_PROFILES = {
    "admin":  {"display_name": "Admin", "avatar_color": "#e85a4f"},
    "rafael": {"display_name": "Rafael", "avatar_color": "#6bb3c4"},
}

# ----- Shared cross-app config (SSO + webhooks) -----
_shared = load_shared_config()
SECRET_KEY = _shared["secret_key"]
INTEGRATION_SECRET = _shared["integration_secret"]
SESSION_COOKIE_DOMAIN = _shared.get("cookie_domain")

# ----- LiveKit -----
LIVEKIT_URL        = _shared.get("livekit_url", "http://localhost:7880")
LIVEKIT_WS_URL     = _shared.get("livekit_ws_url", "ws://localhost:7880")
LIVEKIT_API_KEY    = _shared.get("livekit_api_key", "devkey")
LIVEKIT_API_SECRET = _shared.get("livekit_api_secret", "secret")

MAX_SESSION_PARTICIPANTS = 4
SESSION_STATUSES = ("preparing", "live", "recording", "finished", "archived")
PARTICIPANT_ROLES = ("host", "co-host", "guest")
PARTICIPANT_STATUSES = ("invited", "connected", "active", "disconnected", "left")

# ----- Integration with prePod / postPod -----
POSTPOD_URL = _shared.get("postpod_url", "http://127.0.0.1:5000")
PREPOD_URL  = _shared.get("prepod_url",  "http://127.0.0.1:5001")

# ----- RTMP streaming defaults -----
RTMP_PRESETS = [
    {"key": "youtube", "name": "YouTube Live", "rtmp_url": "rtmp://a.rtmp.youtube.com/live2/"},
    {"key": "twitch",  "name": "Twitch",       "rtmp_url": "rtmp://live.twitch.tv/app/"},
]

# ----- Default soundboard effects -----
# Shortcut keys + mock URLs (real files would go in static/sounds/)
DEFAULT_SOUNDS = [
    {"key": "A", "name": "Aplauso",    "filename": "aplauso.mp3",    "color": "#f4c770"},
    {"key": "R", "name": "Risa",       "filename": "risa.mp3",       "color": "#8db36a"},
    {"key": "B", "name": "Bajos",      "filename": "bajos.mp3",      "color": "#5a8bff"},
    {"key": "I", "name": "Impacto",    "filename": "impacto.mp3",    "color": "#ff3b3b"},
    {"key": "E", "name": "Explosión",  "filename": "explosion.mp3",  "color": "#ff3b3b"},
    {"key": "H", "name": "Horror 1",   "filename": "horror01.mp3",   "color": "#6bb3c4"},
    {"key": "O", "name": "Horror 2",   "filename": "horror02.mp3",   "color": "#6bb3c4"},
    {"key": "T", "name": "Triste 1",   "filename": "triste01.mp3",   "color": "#c7b894"},
    {"key": "S", "name": "Triste 2",   "filename": "triste02.mp3",   "color": "#c7b894"},
    {"key": "Z", "name": "Ronquido",   "filename": "ronquido.mp3",   "color": "#8a7d65"},
]

ALLOWED_SOUND_EXTS = {".mp3", ".wav", ".ogg", ".m4a"}
MAX_SOUND_BYTES = 150 * 1024   # 150 KB
MAX_SOUND_DURATION_SECONDS = 4.0
MAX_SOUNDS_PER_SESSION = 15    # 10 defaults + 5 custom
