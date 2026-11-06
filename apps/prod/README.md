# prodPod

Estudio de grabación en vivo para podcast y videocast. Parte del ecosistema **thePod** (prePod → **prodPod** → postPod).

## Qué hace

prodPod es donde ocurre la grabación: el host crea una sesión, invita participantes por link público (sin cuenta), todos se conectan a una sala WebRTC vía LiveKit, y cada participante graba su propia pista localmente con `MediaRecorder` (estilo Riverside.fm) mientras los chunks se suben en streaming al servidor:

- **Salas WebRTC (LiveKit)** — video/audio en tiempo real, hasta 4 participantes, detección de speaker activo, layout spotlight enfocado en quien habla
- **Grabación client-side por pista** — cada participante graba su track local en calidad original (no comprimido por el SFU) y lo sube en chunks incrementales, con finalize idempotente y recuperación ante cortes de conexión
- **Pre-join screen** — preview de cámara/micrófono y selector de dispositivos antes de entrar a la sala
- **Soundboard** — pack default de 10 sonidos en español + hasta 5 pads custom por sesión (máx. 150 KB / 4 s por sonido), hotkeys, trigger sincronizado a todos vía data channel, normalizado a −20 LUFS, log de triggers con timestamps
- **Chat en vivo** — persistido en DB + delivery instantáneo por data channel
- **Marcadores de capítulo** — el host marca capítulos durante la grabación; viajan a postPod
- **Modo ensayo (práctica)** — sesión completa sin persistir grabaciones
- **Director / Control Room** — rol de director invisible: ve y oye a todos, inyecta overlays en vivo, envía cues privados a los hosts, IFB push-to-talk por host, force-mute, soundboard dual con pads exclusivos, chat de dirección, y control de grabación con cuenta regresiva (habilitado cuando todos los hosts marcan PREPARADO)
- **Teleprompter de sponsors** — panel en vivo con los guiones de sponsors definidos en prePod
- **Streaming RTMP** — a YouTube Live / Twitch vía LiveKit Egress
- **Export a postPod** — al terminar, envía las pistas individuales (una por participante, con `track_number`), capítulos, sound triggers y eventos del director a postPod, que crea el proyecto con todo pre-cargado en el timeline
- **Bundles ZIP** — export/import de sesiones completas (`session.sqlite` + grabaciones + sonidos custom + `manifest.json`)
- **Integración amaPod** — botón AMA que crea un evento de preguntas en amaPod y lo embebe como panel iframe

## Roles

| Rol | Cómo entra | Qué puede hacer |
|-----|-----------|-----------------|
| `host` | Login (cookie SSO) | Crear/editar sesión, grabar, invitar, kick, exportar a postPod |
| `co-host` | Login | Como host dentro del estudio |
| `guest` | Link de invitación público (solo nombre) | Participar, grabar su pista, chat, soundboard |
| `director` | Login + asignado al podcast (`podcast_directors`) | Control Room: overlays, cues, IFB, force-mute, control de grabación, export |

## Stack

| Capa | Tecnología |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3 (CDN, sin bundler), SweetAlert2 |
| Base de datos | SQLite (`main.sqlite`, 11 tablas, WAL) |
| WebRTC | LiveKit (server autoalojado + `livekit-client` 2.18.3 UMD en `static/js/vendor/`) |
| SDK server | `livekit-api` (crear rooms, tokens JWT, Egress RTMP) |
| Grabación | `MediaRecorder` en el navegador (webm vp9/vp8, fallback Safari) |

## Configuración de LiveKit

El servidor LiveKit corre aparte (en dev: Docker, `localhost:7880` HTTP / 7881 TCP / 7882 UDP). prodPod lee su ubicación y credenciales de `~/.podpod/config.json`:

```json
{
  "livekit_url":        "http://localhost:7880",
  "livekit_ws_url":     "ws://localhost:7880",
  "livekit_api_key":    "devkey",
  "livekit_api_secret": "secret"
}
```

`livekit_service.py` crea rooms bajo demanda (`prodpod_session_{id}`) y genera JWT por participante: todos reciben publish/subscribe/publishData; el host además `roomAdmin` + `roomRecord`; el director entra oculto (`hidden`) y solo publica audio IFB.

En producción, el WebSocket se expone vía Apache con `mod_proxy_wstunnel` (vhost `livekit.example.com`).

## Requisitos

- Python 3.9+
- Servidor LiveKit accesible (dev: Docker)
- `ffprobe` (validación de duración de sonidos custom)

```bash
pip install -r requirements.txt
```

## Inicio rápido

```bash
# Desarrollo
python app.py                       # Flask dev server en 0.0.0.0:5002

# Producción
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5002 --timeout 600 'app:create_app()'

# Producción con systemd
sudo cp prodpod.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now prodpod.service
```

Abrir `http://localhost:5002` en el navegador.

**Secretos y usuarios**: no hay credenciales en el repo. La primera vez que arranca cualquier app del ecosistema se crea `~/.podpod/config.json` (vía `shared_config.py`) con `secret_key` e `integration_secret` aleatorios — ese archivo también guarda las credenciales de LiveKit y las URLs de las otras apps. Los usuarios y sus políticas de acceso viven en `~/.podpod/users.db`, compartidos por las tres apps (`shared_users.py`).

## API

~64 endpoints REST agrupados por blueprint:

| Grupo | Cantidad | Auth |
|-------|----------|------|
| Auth (`/api/auth/*`) | 3 | Cookie firmada SSO |
| Sesiones (CRUD, start/stop, participantes, chat, sounds, bundles, AMA) | 30 | Cookie (`@require_auth`) |
| Invitaciones (`/api/invite/{token}/*`: info, join, chat) | 3 | Token público |
| Grabaciones (stream de chunks, upload, listado, download con Range, export a postPod, capítulos, triggers) | 10 | Cookie o `?token=INVITE_TOKEN` |
| Director (tokens, inject, events, assets, cue, force-mute) | 13 | Cookie + rol director |
| Integraciones server-to-server (import de prePod, status, sync-directors, delete-episode) | 4 | Header `X-PodPod-Secret` |

## Ecosistema thePod

```
prePod (puerto 5001)          prodPod (puerto 5002)          postPod (puerto 5000)
─────────────────             ──────────────────             ──────────────────
Pre-producción:               Producción en vivo:            Post-producción:
  Branding                      Salas WebRTC (LiveKit)         Timeline multi-pista
  Kanban de episodios           Grabación por pista            Momentos y efectos
  Scripts                       Soundboard                     Transcripción
  Invitados y sponsors          Chat + director                Subtítulos y karaoke
  Landing pages                 Streaming RTMP                 Composición multi-cámara
                                                               Export FFmpeg
        │                              │
        └──── webhooks ────────────────┘──── webhooks ──────────────┘
              (server-to-server, X-PodPod-Secret)
```

prePod envía episodios a prodPod (crea la sesión de grabación con título, guión y sponsors); al terminar la grabación, prodPod exporta las pistas y metadata a postPod. Las tres apps comparten autenticación (`~/.podpod/users.db`) y configuración (`~/.podpod/config.json`). También se integra con **amaPod** (puerto 5004, eventos de preguntas).

## Estructura del proyecto

```
prodpod/
├── app.py                  # Flask factory, guard de acceso por sesión, migraciones al boot
├── auth.py                 # Sesiones firmadas SSO, @require_auth
├── config.py               # Config compartida, LiveKit, límites del soundboard, roles
├── db.py                   # Schema SQLite (11 tablas: sessions, participants,
│                           #   sound_effects, stream_config, recordings, chat_messages,
│                           #   chapter_markers, sound_triggers, live_streams,
│                           #   podcast_directors, director_events)
├── livekit_service.py      # Rooms, tokens JWT, list_participants
├── sessions_api.py         # CRUD sesiones, chat, sounds, invitaciones, bundles, AMA
├── recordings_api.py       # Streaming de chunks, finalize, capítulos, triggers,
│                           #   export a postPod
├── director_api.py         # Control Room: inject, events, assets, cue, force-mute
├── streams_api.py          # Streaming RTMP vía LiveKit Egress
├── integrations.py         # Webhooks server-to-server (prePod)
├── project_io.py           # Export/import de sesiones como bundles ZIP
├── shared_config.py        # ~/.podpod/config.json (SSO + secretos + URLs)
├── shared_users.py         # ~/.podpod/users.db (usuarios compartidos)
├── migrations/             # Migraciones idempotentes ejecutadas al arrancar
├── static/
│   ├── js/app.js           # SPA Vue 3 (~4500 líneas): Login, Dashboard, Studio,
│   │   │                   #   GuestStudio, Invite, DirectorDashboard, DirectorView
│   │   └── vendor/         # livekit-client UMD, vue, sweetalert2
│   ├── css/style.css       # Tema oscuro "On Air" (rojo signal #ff3b3b)
│   └── sounds/             # Pack default del soundboard
├── templates/index.html    # Shell HTML
├── tests/                  # Tests del módulo director
├── docs/superpowers/       # Specs y planes de diseño (módulo director)
└── sessions/               # Un directorio por sesión (gitignored)
    └── {id}/
        ├── recordings/     # p{pid}_{track}_{hash}.webm por participante
        ├── sounds/         # Pads custom
        └── director_assets/
```

## Documentación adicional

- [`ESTADO.md`](ESTADO.md) — Historial del proyecto fase por fase + cajón de mejoras pendientes
- [`docs/superpowers/specs/2026-05-07-director-module-design.md`](docs/superpowers/specs/2026-05-07-director-module-design.md) — Diseño del módulo director

## Licencia

Proyecto privado.
