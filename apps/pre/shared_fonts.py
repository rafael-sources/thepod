"""
Shared Google Fonts downloader for the podpod suite.

Downloads TTF files from Google Fonts and caches them in ~/.podpod/fonts/
so FFmpeg drawtext can reference them by path. Thread-safe (uses atomic
rename). Font files are never deleted — they're small and reused forever.

Usage:
    from shared_fonts import resolve_font
    path = resolve_font("Fraunces")              # bold (700) preferred
    path = resolve_font("Fraunces", bold=False)  # regular (400)
"""

import re
import urllib.request
from pathlib import Path

FONTS_DIR = Path.home() / ".podpod" / "fonts"


def _sanitize(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")


def _find_cached(font_name: str, weight: int) -> Path | None:
    slug = _sanitize(font_name)
    if not slug:
        return None
    exact = FONTS_DIR / f"{slug}_{weight}.ttf"
    if exact.is_file():
        return exact
    candidates = sorted(FONTS_DIR.glob(f"{slug}_*.ttf"))
    if candidates:
        return candidates[0]
    return None


def _parse_font_faces(css: str) -> list[tuple[int, str]]:
    """Parse @font-face blocks and return [(weight, ttf_url), ...]."""
    results = []
    blocks = re.split(r"@font-face\s*\{", css)
    for block in blocks[1:]:
        weight_m = re.search(r"font-weight:\s*(\d+)", block)
        url_m = re.search(r"url\((https://fonts\.gstatic\.com/[^)]+\.ttf)\)", block)
        if url_m:
            w = int(weight_m.group(1)) if weight_m else 400
            results.append((w, url_m.group(1)))
    return results


def _download_google_font(font_name: str) -> dict[int, Path]:
    """Download both 400 and 700 weights from Google Fonts. Returns {weight: path}."""
    family = font_name.strip().replace(" ", "+")
    css_url = f"https://fonts.googleapis.com/css2?family={family}:wght@400;700&display=swap"
    try:
        req = urllib.request.Request(css_url, headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            css = resp.read().decode("utf-8", errors="replace")
    except Exception:
        return {}

    faces = _parse_font_faces(css)
    if not faces:
        ttf_urls = re.findall(r"url\((https://fonts\.gstatic\.com/[^)]+\.ttf)\)", css)
        if ttf_urls:
            faces = [(400, ttf_urls[0])]
            if len(ttf_urls) > 1:
                faces.append((700, ttf_urls[-1]))

    slug = _sanitize(font_name)
    downloaded = {}
    for weight, url in faces:
        dest = FONTS_DIR / f"{slug}_{weight}.ttf"
        if dest.is_file():
            downloaded[weight] = dest
            continue
        tmp = dest.with_suffix(".tmp")
        try:
            urllib.request.urlretrieve(url, str(tmp))
            if tmp.stat().st_size < 1000:
                tmp.unlink(missing_ok=True)
                continue
            tmp.rename(dest)
            downloaded[weight] = dest
        except Exception:
            tmp.unlink(missing_ok=True)
    return downloaded


def resolve_font(font_name: str, bold: bool = True) -> Path | None:
    """Return local TTF path for a Google Font name, downloading if needed.
    Prefers 700 (bold) for banner overlays; set bold=False for regular."""
    if not font_name or not font_name.strip():
        return None
    FONTS_DIR.mkdir(parents=True, exist_ok=True)
    target_weight = 700 if bold else 400
    cached = _find_cached(font_name, target_weight)
    if cached:
        return cached
    downloaded = _download_google_font(font_name)
    if not downloaded:
        return None
    return downloaded.get(target_weight) or next(iter(downloaded.values()))


def ensure_fonts(*names: str) -> dict[str, Path | None]:
    """Download multiple fonts in one call. Returns {name: path_or_None}."""
    return {n: resolve_font(n) for n in names}
