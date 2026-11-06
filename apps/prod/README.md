# prodPod

Live recording studio for podcasts and videocasts. Part of the **thePod** ecosystem (prePod → **prodPod** → postPod).

## What it does

prodPod is where recording happens: the host creates a session, invites participants via a public link (no account needed), everyone connects to a WebRTC room via LiveKit, and each participant records their own track locally with `MediaRecorder` (Riverside.fm style) while the chunks are streamed up to the server:

- **WebRTC rooms (LiveKit)** — real-time video/audio, up to 4 participants, active speaker detection, spotlight layout focused on whoever is speaking
- **Client-side per-track recording** — each participant records their local track at original quality (not compressed by the SFU) and uploads it in incremental chunks, with idempotent finalize and recovery from connection drops
- **Pre-join screen** — camera/microphone preview and device selector before entering the room
- **Soundboard** — default pack of 10 Spanish-language sounds + up to 5 custom pads per session (max 150 KB / 4 s per sound), hotkeys, trigger synced to everyone via data channel, normalized to −20 LUFS, trigger log with timestamps
- **Live chat** — persisted in the DB + instant delivery via data channel
- **Chapter markers** — the host marks chapters during recording; they travel to postPod
- **Rehearsal mode (practice)** — full session without persisting recordings
- **Director / Control Room** — invisible director role: sees and hears everyone, injects live overlays, sends private cues to hosts, per-host push-to-talk IFB, force-mute, dual soundboard with exclusive pads, direction chat, and recording control with countdown (enabled when all hosts mark PREPARADO)
- **Sponsor teleprompter** — live panel with the sponsor scripts defined in prePod
- **RTMP streaming** — to YouTube Live / Twitch via LiveKit Egress
- **Export to postPod** — when finished, sends the individual tracks (one per participant, with `track_number`), chapters, sound triggers and director events to postPod, which creates the project with everything preloaded on the timeline
- **ZIP bundles** — export/import of full sessions (`session.sqlite` + recordings + custom sounds + `manifest.json`)
- **amaPod integration** — AMA button that creates a Q&A event in amaPod and embeds it as an iframe panel

## Roles

| Role | How they enter | What they can do |
|-----|-----------|-----------------|
| `host` | Login (SSO cookie) | Create/edit session, record, invite, kick, export to postPod |
| `co-host` | Login | Same as host inside the studio |
| `guest` | Public invite link (name only) | Participate, record their track, chat, soundboard |
| `director` | Login + assigned to the podcast (`podcast_directors`) | Control Room: overlays, cues, IFB, force-mute, recording control, export |

## Stack

| Layer | Technology |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3 (CDN, no bundler), SweetAlert2 |
| Database | SQLite (`main.sqlite`, 11 tables, WAL) |
| WebRTC | LiveKit (self-hosted server + `livekit-client` 2.18.3 UMD in `static/js/vendor/`) |
| Server SDK | `livekit-api` (create rooms, JWT tokens, RTMP Egress) |
| Recording | `MediaRecorder` in the browser (webm vp9/vp8, Safari fallback) |

## LiveKit configuration

The LiveKit server runs separately (in dev: Docker, `localhost:7880` HTTP / 7881 TCP / 7882 UDP). prodPod reads its location and credentials from `~/.podpod/config.json`:

```json
{
  "livekit_url":        "http://localhost:7880",
  "livekit_ws_url":     "ws://localhost:7880",
  "livekit_api_key":    "devkey",
  "livekit_api_secret": "secret"
}
```

`livekit_service.py` creates rooms on demand (`prodpod_session_{id}`) and generates a JWT per participant: everyone gets publish/subscribe/publishData; the host also gets `roomAdmin` + `roomRecord`; the director joins hidden (`hidden`) and only publishes IFB audio.

In production, the WebSocket is exposed via Apache with `mod_proxy_wstunnel` (vhost `livekit.example.com`).

## Requirements

- Python 3.9+
- Reachable LiveKit server (dev: Docker)
- `ffprobe` (duration validation of custom sounds)

```bash
pip install -r requirements.txt
```

## Quick start

```bash
# Development
python app.py                       # Flask dev server on 0.0.0.0:5002

# Production
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5002 --timeout 600 'app:create_app()'

# Production with systemd
sudo cp prodpod.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now prodpod.service
```

Open `http://localhost:5002` in the browser.

**Secrets and users**: there are no credentials in the repo. The first time any app of the ecosystem starts, `~/.podpod/config.json` is created (via `shared_config.py`) with random `secret_key` and `integration_secret` — that file also stores the LiveKit credentials and the URLs of the other apps. Users and their access policies live in `~/.podpod/users.db`, shared by the three apps (`shared_users.py`).

## API

~64 REST endpoints grouped by blueprint:

| Group | Count | Auth |
|-------|----------|------|
| Auth (`/api/auth/*`) | 3 | SSO signed cookie |
| Sessions (CRUD, start/stop, participants, chat, sounds, bundles, AMA) | 30 | Cookie (`@require_auth`) |
| Invitations (`/api/invite/{token}/*`: info, join, chat) | 3 | Public token |
| Recordings (chunk streaming, upload, listing, download with Range, export to postPod, chapters, triggers) | 10 | Cookie or `?token=INVITE_TOKEN` |
| Director (tokens, inject, events, assets, cue, force-mute) | 13 | Cookie + director role |
| Server-to-server integrations (prePod import, status, sync-directors, delete-episode) | 4 | `X-PodPod-Secret` header |

## thePod ecosystem

```
prePod (port 5001)            prodPod (port 5002)            postPod (port 5000)
─────────────────             ──────────────────             ──────────────────
Pre-production:               Live production:               Post-production:
  Branding                      WebRTC rooms (LiveKit)         Multi-track timeline
  Episode kanban                Per-track recording            Moments and effects
  Scripts                       Soundboard                     Transcription
  Guests and sponsors           Chat + director                Subtitles and karaoke
  Landing pages                 RTMP streaming                 Multi-camera composition
                                                               FFmpeg export
        │                              │
        └──── webhooks ────────────────┘──── webhooks ──────────────┘
              (server-to-server, X-PodPod-Secret)
```

prePod sends episodes to prodPod (creates the recording session with title, script and sponsors); when recording finishes, prodPod exports the tracks and metadata to postPod. The three apps share authentication (`~/.podpod/users.db`) and configuration (`~/.podpod/config.json`). It also integrates with **amaPod** (port 5004, Q&A events).

## Project structure

```
prodpod/
├── app.py                  # Flask factory, per-session access guard, migrations on boot
├── auth.py                 # SSO signed sessions, @require_auth
├── config.py               # Shared config, LiveKit, soundboard limits, roles
├── db.py                   # SQLite schema (11 tables: sessions, participants,
│                           #   sound_effects, stream_config, recordings, chat_messages,
│                           #   chapter_markers, sound_triggers, live_streams,
│                           #   podcast_directors, director_events)
├── livekit_service.py      # Rooms, JWT tokens, list_participants
├── sessions_api.py         # Sessions CRUD, chat, sounds, invitations, bundles, AMA
├── recordings_api.py       # Chunk streaming, finalize, chapters, triggers,
│                           #   export to postPod
├── director_api.py         # Control Room: inject, events, assets, cue, force-mute
├── streams_api.py          # RTMP streaming via LiveKit Egress
├── integrations.py         # Server-to-server webhooks (prePod)
├── project_io.py           # Export/import of sessions as ZIP bundles
├── shared_config.py        # ~/.podpod/config.json (SSO + secrets + URLs)
├── shared_users.py         # ~/.podpod/users.db (shared users)
├── migrations/             # Idempotent migrations run on startup
├── static/
│   ├── js/app.js           # Vue 3 SPA (~4500 lines): Login, Dashboard, Studio,
│   │   │                   #   GuestStudio, Invite, DirectorDashboard, DirectorView
│   │   └── vendor/         # livekit-client UMD, vue, sweetalert2
│   ├── css/style.css       # "On Air" dark theme (signal red #ff3b3b)
│   └── sounds/             # Default soundboard pack
├── templates/index.html    # HTML shell
├── tests/                  # Director module tests
├── docs/superpowers/       # Design specs and plans (director module)
└── sessions/               # One directory per session (gitignored)
    └── {id}/
        ├── recordings/     # p{pid}_{track}_{hash}.webm per participant
        ├── sounds/         # Custom pads
        └── director_assets/
```

## Additional documentation

- [`ESTADO.md`](ESTADO.md) — Phase-by-phase project history + backlog of pending improvements
- [`docs/superpowers/specs/2026-05-07-director-module-design.md`](docs/superpowers/specs/2026-05-07-director-module-design.md) — Director module design

## License

Private project.
