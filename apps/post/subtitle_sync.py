"""
Places the transcript words where they actually sound (same idea as the Mac app,
macos/Sources/Services/SubtitleSync.swift).

WHY
Whisper's per-word timings come out shifted: a word usually appears between 0.1 and 0.45 s
(sometimes 0.8 s) BEFORE the voice is heard, and subtitles show up before the person speaks.

HOW
It compares "where there are words" with "where the audio sounds" (volume every 10 ms).
1. Over 60 s chunks, it looks for the overall shift (±0.6 s) that best matches the two.
2. Each phrase (words with no pause longer than 0.35 s) is fine-tuned around that shift (±0.6 s).
   A phrase never moves past the previous one, so the order is preserved.
3. A word stretched over a pause is trimmed to the piece where the voice sounds.
Words come back in the SAME order they arrived.
"""

from __future__ import annotations

import wave

import numpy as np

HOP = 0.01          # 10 ms
MAX_SHIFT = 0.6     # maximum shift, in seconds
CHUNK = 60.0        # chunk for the overall shift
PHRASE_GAP = 0.35   # pause that separates phrases
FLOOR_DB = -60.0


def envelope_from_wav(path) -> np.ndarray:
    """Volume in dB every 10 ms of a 16-bit PCM wav (the first channel is used)."""
    with wave.open(str(path), "rb") as wf:
        rate, ch, width = wf.getframerate(), wf.getnchannels(), wf.getsampwidth()
        if width != 2:
            raise ValueError("se esperaba audio de 16 bits")
        hop_n = max(1, int(round(rate * HOP)))
        out, rest = [], np.zeros(0, dtype=np.float32)
        block = hop_n * 6000                       # ~1 minute per read
        while True:
            raw = wf.readframes(block)
            if not raw:
                break
            x = np.frombuffer(raw, dtype="<i2").astype(np.float32)
            if ch > 1:
                x = x[::ch]
            x = np.concatenate([rest, x / 32768.0])
            n = len(x) // hop_n
            rest = x[n * hop_n:]
            if n:
                frames = x[: n * hop_n].reshape(n, hop_n)
                rms = np.sqrt(np.mean(frames * frames, axis=1))
                out.append(np.maximum(FLOOR_DB, 20 * np.log10(rms + 1e-9)))
        if len(rest):
            rms = float(np.sqrt(np.mean(rest * rest)))
            out.append(np.array([max(FLOOR_DB, 20 * np.log10(rms + 1e-9))], dtype=np.float32))
    return np.concatenate(out).astype(np.float32) if out else np.zeros(0, dtype=np.float32)


def _bin(t: float, origin: float) -> int:
    return int(round((t - origin) / HOP))


def _window(env: np.ndarray, t0: float, t1: float) -> np.ndarray:
    """Volume between t0 and t1 (index 0 = t0); outside the audio it stays at −60."""
    n = max(0, int(np.ceil((t1 - t0) / HOP)))
    out = np.full(n, FLOOR_DB, dtype=np.float32)
    a = _bin(t0, 0)
    lo, hi = max(0, a), min(len(env), a + n)
    if hi > lo:
        out[lo - a: hi - a] = env[lo:hi]
    return out


def _zscore(v: np.ndarray) -> np.ndarray:
    d = np.maximum(FLOOR_DB, v.astype(np.float64))
    sd = d.std()
    return (d - d.mean()) / sd if sd > 0 else np.zeros_like(d)


def _loudest(env, origin, t0, t1, threshold):
    """The longest voice stretch (above `threshold` dB) in [t0, t1]; gaps under 0.15 s do not break it."""
    a, b = max(0, _bin(t0, origin)), min(len(env), _bin(t1, origin))
    if b - a <= 2:
        return None
    best, seg_start, last_loud = None, None, -100
    for k in range(a, b):
        if env[k] >= threshold:
            if seg_start is None or k - last_loud > 15:
                seg_start = k
            last_loud = k
            if best is None or (k - seg_start) > (best[1] - best[0]):
                best = (seg_start, k + 1)
    if not best or best[1] - best[0] < 8:          # at least 80 ms of voice
        return None
    return origin + best[0] * HOP, origin + best[1] * HOP


def align(words: list[dict], env: np.ndarray) -> tuple[list[dict], int, float]:
    """`words`: [{"start", "end", ...}] in file time. Returns (adjusted copies, how many
    moved more than 30 ms, typical shift in seconds)."""
    out = [dict(w) for w in words]
    if not words or len(env) < 20:
        return out, 0, 0.0
    idx = sorted(range(len(words)), key=lambda i: words[i]["start"])
    first, last = words[idx[0]]["start"], max(w["end"] for w in words)
    prior, prev_end, shifts = 0.0, -np.inf, []
    steps = int(round(MAX_SHIFT / HOP))

    c0 = first
    while c0 <= last:
        c1 = c0 + CHUNK
        in_chunk = [i for i in idx if c0 <= words[i]["start"] < c1]
        c0 = c1
        if not in_chunk:
            continue
        e0 = words[in_chunk[0]]["start"] - MAX_SHIFT - 0.4
        e1 = max(words[i]["end"] for i in in_chunk) + MAX_SHIFT + 0.4
        win = _window(env, e0, e1)
        if len(win) <= 20:
            continue
        z = _zscore(win)

        def best(lst, center):
            """Shift (s) that best aligns the words in `lst` with the voice, within center ± 0.6 s."""
            a = _bin(words[lst[0]]["start"], e0) - 30
            b = _bin(words[lst[-1]]["end"], e0) + 30
            if b <= a:
                return center
            weight = np.full(b - a, -0.5)
            for i in lst:
                s, e = _bin(words[i]["start"], e0), _bin(words[i]["end"], e0)
                if e > s:
                    weight[max(a, s) - a: min(b, e) - a] = 1.0
            c = int(round(center / HOP))
            best_shift, best_score = center, -np.inf
            for sb in range(c - steps, c + steps + 1):
                lo, hi = max(0, a + sb), min(len(z), b + sb)
                if hi <= lo:
                    continue
                v = float(np.dot(weight[lo - a - sb: hi - a - sb], z[lo:hi])) / (hi - lo)
                if v > best_score:
                    best_score, best_shift = v, sb * HOP
            return best_shift

        # 1. Overall shift for the chunk (only if there is enough speech for it to be reliable)
        speech = sum(max(0.0, words[i]["end"] - words[i]["start"]) for i in in_chunk)
        if speech >= 3:
            prior = best(in_chunk, 0.0)

        # 2. Phrase by phrase
        phrases, cur = [], []
        for i in in_chunk:
            if cur and words[i]["start"] - words[cur[-1]]["end"] > PHRASE_GAP:
                phrases.append(cur)
                cur = []
            cur.append(i)
        if cur:
            phrases.append(cur)
        for ph in phrases:
            f, l = ph[0], ph[-1]
            shift = prior
            if words[l]["end"] - words[f]["start"] >= 0.6:
                shift = best(ph, prior)
            shift = max(shift, prev_end + 0.02 - words[f]["start"])     # do not overlap the previous phrase
            for i in ph:
                s = max(0.0, words[i]["start"] + shift)
                out[i]["start"] = s
                out[i]["end"] = max(s + 0.05, words[i]["end"] + shift)
                shifts.append(shift)
            prev_end = out[l]["end"]

        # 3. Words stretched over a pause: keep only the piece where the voice sounds
        floor = float(np.percentile(win, 20))
        for i in in_chunk:
            dur = out[i]["end"] - out[i]["start"]
            chars = len((out[i].get("word") or "").strip())
            if dur <= max(0.7, 0.3 + 0.09 * chars):
                continue
            seg = _loudest(win, e0, out[i]["start"], out[i]["end"], floor + 12)
            if seg:
                out[i]["start"] = max(out[i]["start"], seg[0] - 0.03)
                out[i]["end"] = min(out[i]["end"], max(out[i]["start"] + 0.08, seg[1] + 0.03))

    moved = sum(1 for o, n in zip(words, out) if abs(o["start"] - n["start"]) > 0.03)
    typical = float(np.median(shifts)) if shifts else 0.0
    return out, moved, typical


def align_segments(segments: list[dict], wav_path) -> tuple[list[dict], int, float]:
    """Adjusts the words of the Whisper segments and recomputes the start and end of each segment."""
    flat, owner = [], []
    for si, seg in enumerate(segments):
        for wi, w in enumerate(seg.get("words") or []):
            if w.get("start") is None or w.get("end") is None:
                continue
            flat.append(w)
            owner.append((si, wi))
    if not flat:
        return segments, 0, 0.0
    env = envelope_from_wav(wav_path)
    new, moved, typical = align(flat, env)
    out = [dict(seg, words=[dict(w) for w in (seg.get("words") or [])]) for seg in segments]
    for (si, wi), w in zip(owner, new):
        out[si]["words"][wi]["start"] = w["start"]
        out[si]["words"][wi]["end"] = w["end"]
    prev_end = 0.0
    for seg in out:
        ws = [w for w in seg["words"] if w.get("start") is not None]
        if ws:
            seg["start"] = max(prev_end, ws[0]["start"])
            seg["end"] = max(seg["start"] + 0.2, ws[-1]["end"])
        prev_end = seg["end"]
    return out, moved, typical
