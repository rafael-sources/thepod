# prePod

Pre-production tool for podcasts and videocasts. Part of the **thePod** ecosystem (**prePod** → prodPod → postPod).

## What it does

prePod covers everything that happens *before* hitting REC: the show's visual identity, episode planning, scripts, guests, sponsors and the podcast's public presence:

- **Branding** — logo, cover, background and landing image (resized with Pillow), color palette and fonts with live preview
- **Episode Kanban** — drag-and-drop board with 6 states (`idea → planning → scripted → recorded → published → archived`)
- **Ideas with voting** — per-episode proposals, idempotent per-user votes, accepted/rejected states
- **Scripts and rundown** — script sections (speaker, content, estimated duration) + reorderable rundown blocks
- **Rundown templates** — reusable templates of blocks and sections to start episodes with structure
- **Guests and RSVP** — per-episode guest CRUD, email invitation with a public RSVP page (token) and attachable .ics
- **Sponsors** — logos, planned offsets in the rundown, ad-read teleprompter, per-sponsor reports (JSON/CSV)
- **Branded emails** — shared SMTP (`email_helper.py`): RSVP invitations, pre-recording prep, co-host invitations, password reset
- **Public landing pages** — 3 templates (minimal / bold / classic) generated with the podcast's branding + **RSS feed** with the `itunes:` namespace
- **Distribution** — platform connection panel (Spotify / Apple Podcasts / YouTube): feed requirements validation, not_configured/pending/connected tracking and verification in the iTunes catalog
- **Publishing** — media upload to own hosting (VPS via rsync/SSH), enclosures in the RSS, optional upload to YouTube (Data API v3 with per-podcast OAuth)
- **AI show notes** — sync of notes generated in postPod, notes panel + "Publicar" button in the episode detail
- **Sound library** — per-podcast sounds + global library; sent to prodPod to preload the studio soundboard
- **Calendar** — .ics export per podcast (feed) or per episode
- **Project Export/Import** — portable ZIP bundle (`manifest.json` + `podcast.db` + branding + sponsors) to back up or migrate podcasts
- **Multi-user** — owner + co-hosts + directors per podcast, user admin, per-podcast access guard on every request

## Stack

| Layer | Technology |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3 (CDN, no bundler), SPA in `static/js/app.js` |
| Database | SQLite (1 DB per podcast: `podcasts/{slug}/proyecto.sqlite`) |
| Images | Pillow (resizing of logos, covers, avatars) |
| Emails | Standard SMTP (shared config) |
| Media hosting | VPS via rsync/SSH (optional) |
| YouTube | Google Data API v3 (optional: `google-auth`, `google-api-python-client`) |

## Requirements

- Python 3.9+
- `pip install -r requirements.txt` (Flask, python-slugify, gunicorn, Pillow, requests)
- Optional for YouTube: `pip install google-auth google-auth-oauthlib google-api-python-client`

## Quick start

```bash
# Development
python app.py                       # 0.0.0.0:5001 with debug

# Production
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5001 --timeout 300 'app:create_app()'
```

Open `http://localhost:5001` in the browser.

### systemd service

The repo includes `prepod.service` (gunicorn as user `admin`, basic hardening):

```bash
sudo cp prepod.service /etc/systemd/system/prepod.service
sudo systemctl daemon-reload
sudo systemctl enable --now prepod.service
```

## Configuration and secrets

**There are no secrets in the repo.** Everything lives in `~/.podpod/` (shared by the three apps):

- `~/.podpod/config.json` (mode 0600, managed by `shared_config.py`) — `secret_key` (cookie signing → SSO across apps), `integration_secret` (server-to-server webhooks), base URLs of prepod/prodpod/postpod/amapod, and optional `smtp`, `hosting` (VPS) and `youtube` (OAuth) blocks. It is generated automatically with random keys the first time any app starts.
- `~/.podpod/users.db` (SQLite WAL, managed by `shared_users.py`) — shared users: logging into one app equals logging into all three.

## API

~125 REST endpoints. Summary by module:

| Module | Endpoints | What it covers |
|--------|-----------|-----------|
| `auth.py` | 5 | login/logout/me, forgot/reset password |
| `podcasts.py` | 13 | podcast CRUD, hosts, directors, invite host, export-bundle / import |
| `branding.py` | 7 | upload/delete of logo, cover, background, landing-image |
| `episodes.py` | 29 | episodes, ideas + votes, script, guests + RSVP, rundown blocks, publish |
| `templates_api.py` | 13 | rundown templates (blocks + sections) |
| `sponsors_api.py` | 8 | sponsors, logos, assignment to blocks, reports |
| `landing.py` | 12 | landing config, per-platform links, team + `GET /landing/{slug}` and `feed.xml` (public) |
| `distribution.py` | 5 | per-platform status, feed validation, catalog check |
| `integrations.py` | 10 | config/ping, send-to-postpod/prodpod, status, prodPod events, exports |
| `sounds.py` | 8 | per-podcast sounds, global library, import |
| `youtube_publish.py` | 5 | OAuth and upload to YouTube |
| `calendar_export.py` | 2 | .ics per podcast and per episode |
| `rsvp.py` | 3 | public RSVP page by token + .ics |
| `users_admin.py` | 4 | user admin |

Auth: signed cookie `podpod_session` (`@require_auth`) for almost everything; landing, RSS and RSVP are public; webhooks between apps use the `X-PodPod-Secret` header.

## API for postPod for Mac (`/api/mac`)

Lets the desktop app publish a finished episode using the configuration
already present in prePod (VPS hosting + RSS feed and YouTube OAuth).
Authentication: the same session from `POST /api/auth/login` (cookie `podpod_session`).

### Chunked upload (files from 100 MB to several GB)

| Method | Path | Description |
|---|---|---|
| POST | `/api/mac/uploads` | `{filename, size}` → `{upload_id}`. Also cleans up abandoned uploads (> 24 h). |
| PUT | `/api/mac/uploads/<upload_id>/chunk?index=N` | Binary body ≤ 16 MB → `{ok, received}`. Sequential: `index` must be the next expected one (409 otherwise). |
| POST | `/api/mac/uploads/<upload_id>/finish` | Verifies the received size matches `size` → `{ok, size}`. |

### Publishing

| Method | Path | Description |
|---|---|---|
| POST | `/api/mac/publish/audio` | `{slug, episode_id, upload_id}` → `{job_id}` (202). Uploads the audio to the VPS with the name `ep{NNN}-{slug}.mp3` and marks the episode as `published` (it enters the Spotify/Apple RSS feed). Returns 409 if the upload is already being published. |
| POST | `/api/mac/publish/youtube` | `{slug, episode_id, upload_id, title, description?, privacy?}` (`privacy`: `public`/`unlisted`/`private`) → `{job_id}` (202). Uploads the video with the podcast's OAuth tokens and saves the URL in `episode_links`. Returns 409 if the upload is already being published. |
| GET | `/api/mac/jobs/<job_id>` | `{status: queued\|running\|done\|error, progress: 0–1, result, error}`. Jobs live in memory: they are lost when the service restarts. |
| GET | `/api/mac/podcasts/<slug>/publish-status?episode_id=N` | `{feed_url, hosting_configured, distribution: [...], youtube: {connected, channel_name}, episode: {title, number, status, media_url, links}}`. |

### nginx (server for the prePod domain)

Chunks weigh up to 16 MB; nginx must allow them. In the `server {}` block of the
prePod domain add (or verify) a specific `location`:

```nginx
location /api/mac/ {
    client_max_body_size 20M;
    proxy_pass http://127.0.0.1:5001;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300s;
}
```

Quick check on the server: `grep -rn "client_max_body_size" /etc/nginx/`
(if the global value is already ≥ 20M, the location is not needed).

## thePod ecosystem

```
prePod (port 5001)            prodPod (port 5002)            postPod (port 5000)
─────────────────             ──────────────────             ──────────────────
Pre-production:               Live production:               Post-production:
  Branding                      WebRTC rooms (LiveKit)         Multi-track timeline
  Episode Kanban                Per-track recording            Moments and effects
  Scripts and rundown           Soundboard                     Transcription
  Guests and sponsors           Chat                           Subtitles and karaoke
  Landing + RSS                 Overlay director               Multi-camera composition
  Distribution                                                 FFmpeg export
        │                              │
        └──── webhooks ────────────────┘──── webhooks ──────────────┘
              (server-to-server, X-PodPod-Secret)
```

The three apps share authentication (`~/.podpod/users.db`) and configuration (`~/.podpod/config.json`), so login is single (SSO). An episode is linked across apps by `shared_project_id` (UUID).

## Project structure

```
prepod/
├── app.py                 # Flask factory, media with HTTP Range, per-podcast access guard
├── auth.py                # Signed sessions, @require_auth, password reset
├── config.py              # Paths, available fonts, per-user policies
├── db.py                  # Per-podcast SQLite schema, idempotent migrations
├── podcasts.py            # Podcast CRUD, hosts/directors, export/import bundle
├── branding.py            # Image uploads with Pillow
├── episodes.py            # Episodes, ideas, scripts, guests, blocks, publish
├── templates_api.py       # Rundown templates
├── sponsors_api.py        # Sponsors + reports
├── landing.py             # Landing config + public render + RSS
├── distribution.py        # Platforms panel (Spotify/Apple/YouTube)
├── project_io.py          # Project export/import as ZIP bundle
├── integrations.py        # Webhooks with postPod/prodPod, exports
├── sounds.py              # Sound library
├── rsvp.py                # Public RSVP by token
├── calendar_export.py     # .ics export
├── email_helper.py        # Branded HTML emails (SMTP)
├── hosting.py             # Media upload to VPS (rsync/SSH)
├── youtube_publish.py     # Upload to YouTube (OAuth Data API v3)
├── users_admin.py         # User admin
├── shared_config.py       # ~/.podpod/config.json (SSO + secrets)
├── shared_users.py        # ~/.podpod/users.db (shared users)
├── shared_fonts.py        # Shared fonts by name
├── static/
│   ├── js/app.js          # Vue 3 SPA (~200 KB)
│   └── css/style.css      # "Green Room" theme (warm-dark, cobalt blue)
├── templates/
│   ├── index.html         # SPA shell
│   ├── rsvp.html          # Public RSVP page
│   └── landing/           # minimal / bold / classic (+ _base)
├── tests/                 # pytest (distribution, hosting)
├── prepod.service         # systemd unit (gunicorn :5001)
└── podcasts/              # One directory per podcast (gitignored)
    └── {slug}/
        ├── proyecto.sqlite
        ├── branding/  sponsors/  sounds/  exports/
```

## Additional documentation

- [`ESTADO.md`](ESTADO.md) — Project history phase by phase + backlog of pending improvements

## License

Private project.
