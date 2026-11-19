# postPod

Non-destructive video and audio editor for podcasts and videocasts. Part of the **thePod** ecosystem (prePod → prodPod → **postPod**).

## What it does

postPod receives the recordings of a live session (individual tracks per participant, sound effects, chapters, director overlays) and lets you edit them on a multi-track timeline without modifying the original files:

- **Multi-track timeline** with trim, reorder, per-clip volume and track assignment
- **Moments and operations** — markers with effects: cuts, zoom, color, comic-style text overlays, camera switch, transitions
- **Audio lane** — parallel track for music and sound effects
- **Automatic transcription** with Whisper (per-word timestamps)
- **Transcript editor** — visual word selection, filler-word removal, inline editing
- **Styled subtitles** — font, color and size customization; word-by-word karaoke for vertical
- **Silence detection** — transcript-based (gaps between words) or FFmpeg silencedetect
- **Multi-camera composition** — 5 layouts: side by side, 2×2 grid, spotlight (active speaker), PiP, solo
- **CNN-style banners** — participants, sponsors, topics, director overlays
- **Speech enhancement** — highpass + denoise + EQ + compressor + loudnorm
- **10 export presets** — YouTube (1080p/4K, 30/60fps), TikTok vertical, Instagram square, WhatsApp, Podcast MP3/M4A

## Composition layouts

| Layout | Description | Participants |
|--------|-------------|---------------|
| Side by side | `hstack` of the tracks, same height | 2 |
| Grid | 2×2 grid, odd panel centered | 3–4 |
| Spotlight | The active speaker (detected by RMS energy) takes the main area | 2+ |
| PiP | Secondary track as picture-in-picture with overlay | 2 |
| Solo | A single track full screen | 1 |

For vertical exports (TikTok/Reels) there is also the **center spotlight** mode: the active speaker centered in 9:16 with word-by-word karaoke subtitles.

## Operations on moments

Each **moment** (marker on the timeline) can have operations that are applied on export:

`color_effect` (grayscale/sepia/invert) · `subtitle` · `text_overlay` (comic stickers with font, rotation and animation) · `remove_silences` · `jump_to_moment` · `switch_track` (camera switch) · `vertical_split` · `audio_mix` / `audio_replace` (SFX) · `zoom_in` / `zoom_out` · `cut_before` / `cut_after` · `insert_clip` · `switch_video` · `to_vertical`

## Export presets

| ID | Output |
|----|--------|
| `yt_1080p_30` / `yt_1080p_60` | 1920×1080 mp4 h264, 30/60 fps |
| `yt_4k_30` / `yt_4k_60` | 3840×2160 mp4 h264, 30/60 fps |
| `std_hd_24` | 1280×720 mp4, 24 fps |
| `tiktok_v` | 1080×1920 vertical (Reels/TikTok) |
| `instagram_sq` | 1080×1080 square |
| `whatsapp` | 1280×720 compressed for sharing |
| `podcast_mp3` / `podcast_m4a` | Audio only (MP3 / AAC) |

## Stack

| Layer | Technology |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3.5 (CDN, no bundler), SweetAlert2 |
| Database | SQLite (1 DB per project, WAL mode) |
| Processing | FFmpeg (composition, filters, encoding) |
| Transcription | faster-whisper (model `Systran/faster-whisper-medium`) |

## Requirements

- Python 3.9+
- FFmpeg with libx264, aac, libmp3lame
- ~2 GB RAM minimum (more for Whisper transcription)

```bash
pip install -r requirements.txt
# Optional, for transcription:
pip install faster-whisper
```

## Quick start

```bash
# Development
flask --app 'app:create_app()' run --port 5000 --debug

# Production
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5000 --timeout 600 'app:create_app()'
```

On first run, `~/.podpod/config.json` is created with random keys and `~/.podpod/users.db` with default users.

Open `http://localhost:5000` in the browser.

## Keyboard shortcuts

| Key | Action |
|-------|--------|
| `Space` | Play/Pause |
| `M` | Create moment at the current time |
| `←` / `→` | Seek ±5s |
| `Shift+←/→` | Seek by frame (±1/30s) |
| `+` / `-` | Timeline zoom |
| `Z` | Zoom to selection |
| `Esc` | Clear selection |
| `Del` | Delete selected words (TranscriptEditor) |

## API

78 REST endpoints in total:

| Group | Count | Auth |
|-------|----------|------|
| User session (projects, timeline, moments, captions, exports) | 56 | Signed cookie (`@require_auth`) |
| Server-to-server (prePod/prodPod webhooks) | 13 | `X-PodPod-Secret` header |
| Public (login, media with HTTP Range, health) | 9 | — |

The full detail of each endpoint (method, route, payload) is in [`HANDOVER_POSTPRODUCCION.md`](HANDOVER_POSTPRODUCCION.md) §5.

## thePod ecosystem

```
prePod (port 5001)            prodPod (port 5002)            postPod (port 5000)
─────────────────             ──────────────────             ──────────────────
Pre-production:               Live production:               Post-production:
  Branding                      WebRTC rooms (LiveKit)         Multi-track timeline
  Episode Kanban                Per-track recording            Moments and effects
  Scripts                       Soundboard                     Transcription
  Guests and sponsors           Chat                           Subtitles and karaoke
  Landing pages                 Overlay director               Multi-camera composition
                                                               FFmpeg export
        │                              │
        └──── webhooks ────────────────┘──── webhooks ──────────────┘
              (server-to-server, X-PodPod-Secret)
```

The three apps share authentication (`~/.podpod/users.db`) and configuration (`~/.podpod/config.json`).

## Project structure

```
postpod/
├── app.py                 # Flask factory, media serving with HTTP Range
├── auth.py                # Signed sessions, @require_auth
├── config.py              # Paths, export presets, fonts
├── db.py                  # SQLite schema (13 tables), idempotent migrations
├── exporter.py            # FFmpeg pipeline (3100+ lines): composition, layouts,
│                          #   karaoke, banners, speech enhancement, threading
├── files.py               # Upload/download, thumbnails, waveforms
├── timeline_api.py        # Timeline CRUD, moments, operations, silences
├── captions.py            # Whisper, SRT, words.json, subtitle styles
├── integrations.py        # Server-to-server webhooks (prePod/prodPod)
├── projects.py            # Projects, participants, sponsors CRUD
├── static/
│   ├── js/app.js          # Vue 3 SPA (19 components, ~5100 lines)
│   ├── css/style.css      # "Broadcast booth" dark theme
│   └── fonts/             # Comic fonts for text overlays
├── templates/index.html   # HTML shell
├── global/audio/          # Sound effects library
└── projects/              # One directory per project (gitignored)
    └── {slug}/
        ├── proyecto.json / proyecto.sqlite
        ├── media/{video,audio,image}/
        ├── exports/
        ├── branding/
        └── director_assets/
```

## Additional documentation

- [`HANDOVER_POSTPRODUCCION.md`](HANDOVER_POSTPRODUCCION.md) — Full technical document (1200+ lines) for porting post-production to a native macOS app: SQL schema of the 13 tables, the 85 endpoints, FFmpeg pipeline, 21 fragile points, portable bundle spec and an appendix with real data examples (words.json, operation params, webhook payloads, FFmpeg command, processing times)
- [`ESTADO.md`](ESTADO.md) — Project history phase by phase (Phase 1 auth/projects → Phase 12 CapCut features) + backlog of pending improvements

## License

Private project.
