import hashlib
from pathlib import Path

from shared_config import load_shared_config


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


BASE_DIR = Path(__file__).resolve().parent
SESSIONS_DIR = BASE_DIR / "sessions"
SOUNDS_DIR = BASE_DIR / "static" / "sounds"

# Users + policy live in ~/.podpod/users.json (read by all 3 apps).
from shared_users import (
    users_passwords as _users_passwords,
    users_profiles as _users_profiles,
    users_policy as _users_policy,
    policy_for as _policy_for,
)


def _live_dict(fn):
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

# ----- LiveKit -----
LIVEKIT_URL        = _shared.get("livekit_url", "http://localhost:7880")
LIVEKIT_WS_URL     = _shared.get("livekit_ws_url", "ws://localhost:7880")
LIVEKIT_API_KEY    = _shared.get("livekit_api_key", "devkey")
LIVEKIT_API_SECRET = _shared.get("livekit_api_secret", "secret")

MAX_SESSION_PARTICIPANTS = 4
SESSION_STATUSES = ("preparing", "live", "recording", "finished", "archived")
PARTICIPANT_ROLES = ("host", "co-host", "guest", "director")
PARTICIPANT_STATUSES = ("invited", "connected", "active", "disconnected", "left")

# ----- Integration with prePod / postPod -----
POSTPOD_URL = _shared.get("postpod_url", "http://127.0.0.1:5000")
# Llamadas servidor a servidor (envío de pistas, capítulos…): directo a
# postPod dentro de la misma máquina, sin pasar por el proxy público, que
# corta subidas de varios GB y responde 502 si postPod tarda en contestar.
POSTPOD_INTERNAL_URL = (_shared.get("postpod_internal_url") or "http://127.0.0.1:5000").rstrip("/")
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
