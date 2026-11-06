# amaPod

Sesiones AMA (Ask Me Anything) y eventos en vivo con audiencia. Parte del ecosistema **thePod** (prePod → prodPod → postPod → **amaPod**).

## Qué hace

amaPod permite a un host crear un evento en vivo (sala LiveKit) donde la audiencia solicita participar, espera su turno en una cola gestionada por el host, y sale "al aire" uno a uno para hacer sus preguntas. Los espectadores pueden mirar sin participar, dar likes y chatear.

- **Eventos con ciclo de vida** — `created` → `active` → `finished`; plantillas reutilizables (clonar un evento como template y crear nuevos desde él)
- **Cola de participantes** — la audiencia solicita acceso con solo su nombre (sin registro); el host aprueba/rechaza, reordena la cola con drag & drop, salta a cualquier participante o pasa al siguiente
- **Turnos al aire** — solo el participante `on_air` puede publicar audio/video; los permisos de LiveKit se actualizan server-side en cada cambio de turno
- **Preconexión** — los próximos 3 en la cola (`PRECONNECT_COUNT`) se marcan para preconectarse y que el cambio de turno sea instantáneo
- **Pre-preguntas** — cada participante puede escribir hasta 3 preguntas mientras espera; el host las ve en la cola y durante el turno
- **Censura** — el host puede mutear y revocar publicación a cualquier participante (y restaurarla)
- **Modo espectador** — vista pública `/watch/{id}` con token subscribe-only, contador de espectadores y botón de likes
- **Chat** — tres modos por evento: `free`, `moderated` (mensajes de no-host requieren aprobación) y `off`
- **Grabación** — LiveKit Egress (room composite → MP4 en `events/{id}/recordings/`), con auto-export a postPod al finalizar el evento
- **Integraciones** — prodPod puede crear un evento amaPod en caliente (embed durante una grabación); la grabación se exporta a postPod como track de video

## Stack

| Capa | Tecnología |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3 (CDN, sin bundler), SweetAlert2, livekit-client 2.x (UMD en `static/js/vendor/`) |
| Base de datos | SQLite (`main.sqlite`, WAL mode, migraciones idempotentes) |
| Video en vivo | LiveKit (rooms, tokens JWT, permisos por participante, Egress) |

## Inicio rápido

```bash
pip install -r requirements.txt   # Flask, gunicorn, livekit-api, PyJWT

# Desarrollo (puerto 5004)
python app.py
# o
flask --app 'app:create_app()' run --port 5004 --debug

# Producción
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5004 --timeout 600 'app:create_app()'
```

La primera vez se crean `~/.podpod/config.json` (claves aleatorias) y `~/.podpod/users.db` (usuarios por defecto). Abrir `http://localhost:5004`.

### Servicio systemd

```bash
sudo cp amapod.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now amapod.service
```

El servicio corre gunicorn en `0.0.0.0:5004` como usuario `admin`, con `ReadWritePaths` limitado a `/srv/thepod/amapod` y `/srv/thepod/.podpod`.

## Rutas del SPA

| Ruta | Vista | Auth |
|------|-------|------|
| `/` | Login → Dashboard → Host studio | Cookie firmada |
| `/join/{id}` | Participante: solicitar acceso, cola, al aire | Token de acceso (uuid) |
| `/watch/{id}` | Espectador: ver, likes, chat | Ninguna |
| `/embed/{id}` | Host embebido (para prodPod) | Cookie firmada |

## API

44 endpoints REST en 6 blueprints:

| Grupo | Endpoints | Auth |
|-------|-----------|------|
| `auth.py` — login/logout/me | 3 | — / cookie |
| `events_api.py` — CRUD, start/finish, like, spectator-token, templates | 13 | Cookie (`@require_auth`); public-info, like y spectator-token son públicos |
| `queue_api.py` — request-access, my-status, my-questions, cola, approve/reject, next/skip/reorder, censor/uncensor, remove, tokens LiveKit | 15 | Host por cookie; participante por `?token=` |
| `recording_api.py` — start/stop/status/download de egress | 4 | Cookie |
| `chat_api.py` — enviar/listar/aprobar/eliminar mensajes | 4 | Cookie o token de participante |
| `integrations.py` — create-event desde prodPod, export a postPod, import stub de prePod | 3 | Header `X-PodPod-Secret` (export: cookie) |

Más 2 endpoints de configuración en `app.py` (`/api/config/apps`, `/api/config/livekit`).

## Estados

- **Evento**: `created` → `active` → `finished`
- **Participante**: `pending` → `in_queue` → `on_air` → `done` (o `rejected` / `left`)
- **Chat**: `free` · `moderated` · `off`

## Ecosistema thePod

```
prePod (5001)      prodPod (5002)      postPod (5000)      amaPod (5004)
Pre-producción     Grabación en vivo   Post-producción     Eventos AMA en vivo
```

- prodPod → amaPod: `POST /api/integrations/prodpod/create-event` crea un evento activo y devuelve una `embed_url` para incrustar durante una sesión.
- amaPod → postPod: al finalizar un evento con grabación, se exporta automáticamente el MP4 a postPod (`/api/integrations/prodpod/import-track`) con un `shared_project_id`.

**Secretos y usuarios compartidos**: la configuración sensible (SECRET_KEY, INTEGRATION_SECRET, credenciales LiveKit, URLs de las apps, cookie domain) viene de `~/.podpod/config.json` vía `shared_config.py`; los usuarios y perfiles viven en `~/.podpod/users.db` vía `shared_users.py`. El SECRET_KEY compartido da SSO entre las cuatro apps (cookie `podpod_session`).

## Estructura del proyecto

```
amapod/
├── app.py               # Flask factory, SPA catch-all, config endpoints
├── auth.py              # Sesiones signed-cookie, @require_auth (SSO suite)
├── config.py            # Constantes + carga de shared config/users
├── db.py                # Schema SQLite (4 tablas) + migraciones idempotentes
├── events_api.py        # CRUD eventos, ciclo de vida, likes, templates
├── queue_api.py         # Cola de participantes, turnos, censura, tokens
├── recording_api.py     # Grabación vía LiveKit Egress
├── chat_api.py          # Chat free/moderated/off
├── integrations.py      # Webhooks prodPod/postPod/prePod
├── livekit_service.py   # Wrapper asyncio del SDK LiveKit
├── shared_config.py     # ~/.podpod/config.json (compartido con la suite)
├── shared_users.py      # ~/.podpod/users.db (compartido con la suite)
├── amapod.service       # Unidad systemd (gunicorn :5004)
├── static/
│   ├── js/app.js        # SPA Vue 3 (7 vistas)
│   ├── js/vendor/       # vue, livekit-client, sweetalert2
│   └── css/style.css    # Design system de la suite
├── templates/index.html # Shell HTML
├── tests/               # 46 tests pytest (db, events, queue, chat, recording, integrations)
└── events/              # Un directorio por evento: recordings/, chat/ (gitignored)
```

## Tests

```bash
pytest tests/
```

## Documentación adicional

- [`ESTADO.md`](ESTADO.md) — Historial del proyecto fase por fase + cajón de mejoras pendientes

## Licencia

Proyecto privado.
