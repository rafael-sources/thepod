# amaPod

AMA (Ask Me Anything) sessions and live events with an audience. Part of the **thePod** ecosystem (prePod → prodPod → postPod → **amaPod**).

## What it does

amaPod lets a host create a live event (LiveKit room) where the audience requests to participate, waits for their turn in a queue managed by the host, and goes "on air" one by one to ask their questions. Spectators can watch without participating, give likes and chat.

- **Events with a lifecycle** — `created` → `active` → `finished`; reusable templates (clone an event as a template and create new ones from it)
- **Participant queue** — the audience requests access with just their name (no sign-up); the host approves/rejects, reorders the queue with drag & drop, jumps to any participant or moves to the next one
- **On-air turns** — only the `on_air` participant can publish audio/video; LiveKit permissions are updated server-side on every turn change
- **Preconnection** — the next 3 in the queue (`PRECONNECT_COUNT`) are flagged to preconnect so the turn change is instant
- **Pre-questions** — each participant can write up to 3 questions while waiting; the host sees them in the queue and during the turn
- **Censorship** — the host can mute and revoke publishing for any participant (and restore it)
- **Spectator mode** — public view `/watch/{id}` with a subscribe-only token, viewer counter and like button
- **Chat** — three modes per event: `free`, `moderated` (non-host messages require approval) and `off`
- **Recording** — LiveKit Egress (room composite → MP4 in `events/{id}/recordings/`), with auto-export to postPod when the event finishes
- **Integrations** — prodPod can create an amaPod event on the fly (embed during a recording); the recording is exported to postPod as a video track

## Stack

| Layer | Technology |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3 (CDN, no bundler), SweetAlert2, livekit-client 2.x (UMD in `static/js/vendor/`) |
| Database | SQLite (`main.sqlite`, WAL mode, idempotent migrations) |
| Live video | LiveKit (rooms, JWT tokens, per-participant permissions, Egress) |

## Quick start

```bash
pip install -r requirements.txt   # Flask, gunicorn, livekit-api, PyJWT

# Development (port 5004)
python app.py
# or
flask --app 'app:create_app()' run --port 5004 --debug

# Production
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5004 --timeout 600 'app:create_app()'
```

On first run, `~/.podpod/config.json` (random keys) and `~/.podpod/users.db` (default users) are created. Open `http://localhost:5004`.

### systemd service

```bash
sudo cp amapod.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now amapod.service
```

The service runs gunicorn on `0.0.0.0:5004` as user `admin`, with `ReadWritePaths` limited to `/srv/thepod/amapod` and `/srv/thepod/.podpod`.

## SPA routes

| Route | View | Auth |
|------|-------|------|
| `/` | Login → Dashboard → Host studio | Signed cookie |
| `/join/{id}` | Participant: request access, queue, on air | Access token (uuid) |
| `/watch/{id}` | Spectator: watch, likes, chat | None |
| `/embed/{id}` | Embedded host (for prodPod) | Signed cookie |

## API

44 REST endpoints in 6 blueprints:

| Group | Endpoints | Auth |
|-------|-----------|------|
| `auth.py` — login/logout/me | 3 | — / cookie |
| `events_api.py` — CRUD, start/finish, like, spectator-token, templates | 13 | Cookie (`@require_auth`); public-info, like and spectator-token are public |
| `queue_api.py` — request-access, my-status, my-questions, queue, approve/reject, next/skip/reorder, censor/uncensor, remove, LiveKit tokens | 15 | Host via cookie; participant via `?token=` |
| `recording_api.py` — egress start/stop/status/download | 4 | Cookie |
| `chat_api.py` — send/list/approve/delete messages | 4 | Cookie or participant token |
| `integrations.py` — create-event from prodPod, export to postPod, prePod import stub | 3 | `X-PodPod-Secret` header (export: cookie) |

Plus 2 config endpoints in `app.py` (`/api/config/apps`, `/api/config/livekit`).

## States

- **Event**: `created` → `active` → `finished`
- **Participant**: `pending` → `in_queue` → `on_air` → `done` (or `rejected` / `left`)
- **Chat**: `free` · `moderated` · `off`

## thePod ecosystem

```
prePod (5001)      prodPod (5002)      postPod (5000)      amaPod (5004)
Pre-production     Live recording      Post-production     Live AMA events
```

- prodPod → amaPod: `POST /api/integrations/prodpod/create-event` creates an active event and returns an `embed_url` to embed during a session.
- amaPod → postPod: when an event with a recording finishes, the MP4 is automatically exported to postPod (`/api/integrations/prodpod/import-track`) with a `shared_project_id`.

**Shared secrets and users**: sensitive configuration (SECRET_KEY, INTEGRATION_SECRET, LiveKit credentials, app URLs, cookie domain) comes from `~/.podpod/config.json` via `shared_config.py`; users and profiles live in `~/.podpod/users.db` via `shared_users.py`. The shared SECRET_KEY provides SSO across the four apps (cookie `podpod_session`).

## Project structure

```
amapod/
├── app.py               # Flask factory, SPA catch-all, config endpoints
├── auth.py              # Signed-cookie sessions, @require_auth (suite SSO)
├── config.py            # Constants + loading of shared config/users
├── db.py                # SQLite schema (4 tables) + idempotent migrations
├── events_api.py        # Events CRUD, lifecycle, likes, templates
├── queue_api.py         # Participant queue, turns, censorship, tokens
├── recording_api.py     # Recording via LiveKit Egress
├── chat_api.py          # free/moderated/off chat
├── integrations.py      # prodPod/postPod/prePod webhooks
├── livekit_service.py   # asyncio wrapper for the LiveKit SDK
├── shared_config.py     # ~/.podpod/config.json (shared with the suite)
├── shared_users.py      # ~/.podpod/users.db (shared with the suite)
├── amapod.service       # systemd unit (gunicorn :5004)
├── static/
│   ├── js/app.js        # Vue 3 SPA (7 views)
│   ├── js/vendor/       # vue, livekit-client, sweetalert2
│   └── css/style.css    # Suite design system
├── templates/index.html # HTML shell
├── tests/               # 46 pytest tests (db, events, queue, chat, recording, integrations)
└── events/              # One directory per event: recordings/, chat/ (gitignored)
```

## Tests

```bash
pytest tests/
```

## Additional documentation

- [`ESTADO.md`](ESTADO.md) — Project history phase by phase + backlog of pending improvements

## License

Private project.
