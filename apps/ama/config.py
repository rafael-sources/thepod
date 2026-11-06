import hashlib
from pathlib import Path
from shared_config import load_shared_config

def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()

BASE_DIR = Path(__file__).resolve().parent
EVENTS_DIR = BASE_DIR / "events"

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

_shared = load_shared_config()
SECRET_KEY = _shared["secret_key"]
INTEGRATION_SECRET = _shared["integration_secret"]
SESSION_COOKIE_DOMAIN = _shared.get("cookie_domain")

LIVEKIT_URL        = _shared.get("livekit_url", "http://localhost:7880")
LIVEKIT_WS_URL     = _shared.get("livekit_ws_url", "ws://localhost:7880")
LIVEKIT_API_KEY    = _shared.get("livekit_api_key", "devkey")
LIVEKIT_API_SECRET = _shared.get("livekit_api_secret", "secret")

EVENT_STATUSES = ("created", "active", "finished")
PARTICIPANT_STATUSES = ("pending", "approved", "in_queue", "on_air", "done", "rejected", "left")
CHAT_MODES = ("free", "moderated", "off")
PRECONNECT_COUNT = 3
RECONNECT_TIMEOUT_SECONDS = 10

POSTPOD_URL = _shared.get("postpod_url", "http://127.0.0.1:5000")
PREPOD_URL  = _shared.get("prepod_url",  "http://127.0.0.1:5001")
PRODPOD_URL = _shared.get("prodpod_url", "http://127.0.0.1:5002")
AMAPOD_URL  = _shared.get("amapod_url",  "http://127.0.0.1:5003")
