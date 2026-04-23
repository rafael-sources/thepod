import hashlib
from pathlib import Path

from shared_config import load_shared_config


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


BASE_DIR = Path(__file__).resolve().parent
PROJECTS_DIR = BASE_DIR / "projects"
GLOBAL_DIR = BASE_DIR / "global"

USERS = {
    "admin":  md5("CAMBIAR-EN-PRIMER-ARRANQUE"),
    "rafael": md5("CAMBIAR-EN-PRIMER-ARRANQUE"),
}

# ----- Shared cross-app config (SSO + webhooks) -----
_shared = load_shared_config()
SECRET_KEY = _shared["secret_key"]
INTEGRATION_SECRET = _shared["integration_secret"]
SESSION_COOKIE_DOMAIN = _shared.get("cookie_domain")

MEDIA_TYPES = ("video", "audio", "image")

ALLOWED_EXTS = {
    "video": {".mp4", ".mov", ".webm"},
    "audio": {".mp3", ".wav", ".m4a"},
    "image": {".jpg", ".jpeg", ".png", ".gif"},
}


def ext_to_type(ext: str) -> str | None:
    ext = ext.lower()
    for t, exts in ALLOWED_EXTS.items():
        if ext in exts:
            return t
    return None


# Candidate font files used by ffmpeg drawtext. First one that exists wins.
DRAWTEXT_FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
]

# Comic-style fonts shipped with postpod (in static/fonts/). Keys match the
# frontend's font picker. All are OFL/Apache-licensed (redistributable).
COMIC_FONTS = {
    "bangers":          str(BASE_DIR / "static" / "fonts" / "Bangers-Regular.ttf"),
    "titan_one":        str(BASE_DIR / "static" / "fonts" / "TitanOne-Regular.ttf"),
    "luckiest_guy":     str(BASE_DIR / "static" / "fonts" / "LuckiestGuy-Regular.ttf"),
    "permanent_marker": str(BASE_DIR / "static" / "fonts" / "PermanentMarker-Regular.ttf"),
}
DEFAULT_COMIC_FONT = "bangers"


EXPORT_PRESETS = [
    {"id": "yt_1080p_30",  "name": "YouTube 1080p 30fps",       "width": 1920, "height": 1080, "fps": 30, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "YouTube"},
    {"id": "yt_1080p_60",  "name": "YouTube 1080p 60fps",       "width": 1920, "height": 1080, "fps": 60, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "YouTube"},
    {"id": "yt_4k_30",     "name": "YouTube 4K 30fps",          "width": 3840, "height": 2160, "fps": 30, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "YouTube"},
    {"id": "yt_4k_60",     "name": "YouTube 4K 60fps",          "width": 3840, "height": 2160, "fps": 60, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "YouTube"},
    {"id": "std_hd_24",    "name": "HD 720p 24fps",             "width": 1280, "height": 720,  "fps": 24, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "General"},
    {"id": "tiktok_v",     "name": "TikTok / Reels vertical",   "width": 1080, "height": 1920, "fps": 30, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "TikTok / Reels"},
    {"id": "instagram_sq", "name": "Instagram cuadrado",        "width": 1080, "height": 1080, "fps": 30, "format": "mp4",  "vcodec": "libx264", "acodec": "aac",        "platform": "Instagram"},
    {"id": "whatsapp",     "name": "WhatsApp",                  "width": 1280, "height": 720,  "fps": 30, "format": "mp4",  "vcodec": "libx264", "acodec": "aac", "bitrate": "2M", "platform": "WhatsApp"},
    {"id": "podcast_mp3",  "name": "Podcast MP3",               "width": None, "height": None, "fps": None, "format": "mp3", "vcodec": None,     "acodec": "libmp3lame", "platform": "Podcast"},
    {"id": "podcast_m4a",  "name": "Podcast M4A (AAC)",         "width": None, "height": None, "fps": None, "format": "m4a", "vcodec": None,     "acodec": "aac",        "platform": "Podcast"},
]


def find_preset(preset_id):
    for p in EXPORT_PRESETS:
        if p["id"] == preset_id:
            return p
    return None


def drawtext_fontfile() -> str | None:
    from os.path import isfile
    for c in DRAWTEXT_FONT_CANDIDATES:
        if isfile(c):
            return c
    return None
