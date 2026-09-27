# prePod

Herramienta de pre-producción para podcasts y videocasts. Parte del ecosistema **thePod** (**prePod** → prodPod → postPod).

## Qué hace

prePod cubre todo lo que ocurre *antes* de apretar REC: identidad visual del show, planificación de episodios, guiones, invitados, sponsors y la presencia pública del podcast:

- **Branding** — logo, cover, background e imagen de landing (resize con Pillow), paleta de colores y fuentes con live preview
- **Kanban de episodios** — tablero drag-and-drop con 6 estados (`idea → planning → scripted → recorded → published → archived`)
- **Ideas con voting** — propuestas por episodio, votos idempotentes por usuario, estados accepted/rejected
- **Scripts y rundown** — secciones de guion (speaker, contenido, duración estimada) + bloques de rundown reordenables
- **Templates de rundown** — plantillas reutilizables de bloques y secciones para arrancar episodios con estructura
- **Invitados y RSVP** — CRUD de invitados por episodio, invitación por email con página RSVP pública (token) y .ics adjuntable
- **Sponsors** — logos, offsets planificados en el rundown, teleprompter de ad-reads, reportes por sponsor (JSON/CSV)
- **Emails con marca** — SMTP compartido (`email_helper.py`): invitaciones RSVP, preparación pre-grabación, invitación de co-hosts, reset de contraseña
- **Landing pages públicas** — 3 templates (minimal / bold / classic) generadas con el branding del podcast + **feed RSS** con namespace `itunes:`
- **Distribución** — panel de conexión a plataformas (Spotify / Apple Podcasts / YouTube): validación de requisitos del feed, seguimiento not_configured/pending/connected y verificación en el catálogo de iTunes
- **Publicación** — subida de media a hosting propio (VPS vía rsync/SSH), enclosures en el RSS, upload opcional a YouTube (Data API v3 con OAuth por podcast)
- **Show notes con IA** — sincronización de notas generadas en postPod, panel de notas + botón "Publicar" en el detalle del episodio
- **Biblioteca de sonidos** — sonidos por podcast + librería global; se envían a prodPod para precargar el soundboard del estudio
- **Calendario** — export .ics por podcast (feed) o por episodio
- **Export/Import de proyectos** — bundle ZIP portable (`manifest.json` + `podcast.db` + branding + sponsors) para respaldar o migrar podcasts
- **Multiusuario** — owner + co-hosts + directores por podcast, admin de usuarios, guard de acceso por podcast en cada request

## Stack

| Capa | Tecnología |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3 (CDN, sin bundler), SPA en `static/js/app.js` |
| Base de datos | SQLite (1 DB por podcast: `podcasts/{slug}/proyecto.sqlite`) |
| Imágenes | Pillow (resize de logos, covers, avatares) |
| Emails | SMTP estándar (config compartida) |
| Hosting de media | VPS vía rsync/SSH (opcional) |
| YouTube | Google Data API v3 (opcional: `google-auth`, `google-api-python-client`) |

## Requisitos

- Python 3.9+
- `pip install -r requirements.txt` (Flask, python-slugify, gunicorn, Pillow, requests)
- Opcional para YouTube: `pip install google-auth google-auth-oauthlib google-api-python-client`

## Inicio rápido

```bash
# Desarrollo
python app.py                       # 0.0.0.0:5001 con debug

# Producción
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5001 --timeout 300 'app:create_app()'
```

Abrir `http://localhost:5001` en el navegador.

### Servicio systemd

El repo incluye `prepod.service` (gunicorn como usuario `admin`, hardening básico):

```bash
sudo cp prepod.service /etc/systemd/system/prepod.service
sudo systemctl daemon-reload
sudo systemctl enable --now prepod.service
```

## Configuración y secretos

**No hay secretos en el repo.** Todo vive en `~/.podpod/` (compartido por las tres apps):

- `~/.podpod/config.json` (modo 0600, gestionado por `shared_config.py`) — `secret_key` (firma de cookies → SSO entre apps), `integration_secret` (webhooks server-to-server), URLs base de prepod/prodpod/postpod/amapod, y bloques opcionales `smtp`, `hosting` (VPS) y `youtube` (OAuth). Se genera solo con claves aleatorias la primera vez que arranca cualquier app.
- `~/.podpod/users.db` (SQLite WAL, gestionado por `shared_users.py`) — usuarios compartidos: login en una app equivale a login en las tres.

## API

~125 endpoints REST. Resumen por módulo:

| Módulo | Endpoints | Qué cubre |
|--------|-----------|-----------|
| `auth.py` | 5 | login/logout/me, forgot/reset password |
| `podcasts.py` | 13 | CRUD podcasts, hosts, directores, invitar host, export-bundle / import |
| `branding.py` | 7 | upload/delete de logo, cover, background, landing-image |
| `episodes.py` | 29 | episodios, ideas + votos, script, invitados + RSVP, bloques de rundown, publish |
| `templates_api.py` | 13 | templates de rundown (bloques + secciones) |
| `sponsors_api.py` | 8 | sponsors, logos, asignación a bloques, reportes |
| `landing.py` | 12 | config de landing, links por plataforma, equipo + `GET /landing/{slug}` y `feed.xml` (públicos) |
| `distribution.py` | 5 | estado por plataforma, validación de feed, check en catálogos |
| `integrations.py` | 10 | config/ping, send-to-postpod/prodpod, status, eventos de prodPod, exports |
| `sounds.py` | 8 | sonidos por podcast, librería global, import |
| `youtube_publish.py` | 5 | OAuth y upload a YouTube |
| `calendar_export.py` | 2 | .ics por podcast y por episodio |
| `rsvp.py` | 3 | página RSVP pública por token + .ics |
| `users_admin.py` | 4 | admin de usuarios |

Auth: cookie firmada `podpod_session` (`@require_auth`) para casi todo; landing, RSS y RSVP son públicos; los webhooks entre apps usan el header `X-PodPod-Secret`.

## API para postPod de Mac (`/api/mac`)

Permite que la app de escritorio publique un episodio terminado usando la
configuración ya existente en prePod (hosting VPS + feed RSS y YouTube OAuth).
Autenticación: la misma sesión de `POST /api/auth/login` (cookie `podpod_session`).

### Subida por partes (archivos de 100 MB a varios GB)

| Método | Ruta | Descripción |
|---|---|---|
| POST | `/api/mac/uploads` | `{filename, size}` → `{upload_id}`. También limpia uploads abandonados (> 24 h). |
| PUT | `/api/mac/uploads/<upload_id>/chunk?index=N` | Cuerpo binario ≤ 16 MB → `{ok, received}`. Secuencial: `index` debe ser el siguiente esperado (409 si no). |
| POST | `/api/mac/uploads/<upload_id>/finish` | Verifica que el tamaño recibido coincida con `size` → `{ok, size}`. |

### Publicación

| Método | Ruta | Descripción |
|---|---|---|
| POST | `/api/mac/publish/audio` | `{slug, episode_id, upload_id}` → `{job_id}` (202). Sube el audio a VPS con el nombre `ep{NNN}-{slug}.mp3` y marca el episodio como `published` (entra al feed RSS de Spotify/Apple). Devuelve 409 si el upload ya está siendo publicado. |
| POST | `/api/mac/publish/youtube` | `{slug, episode_id, upload_id, title, description?, privacy?}` (`privacy`: `public`/`unlisted`/`private`) → `{job_id}` (202). Sube el video con los tokens OAuth del podcast y guarda la URL en `episode_links`. Devuelve 409 si el upload ya está siendo publicado. |
| GET | `/api/mac/jobs/<job_id>` | `{status: queued\|running\|done\|error, progress: 0–1, result, error}`. Los jobs viven en memoria: se pierden al reiniciar el servicio. |
| GET | `/api/mac/podcasts/<slug>/publish-status?episode_id=N` | `{feed_url, hosting_configured, distribution: [...], youtube: {connected, channel_name}, episode: {title, number, status, media_url, links}}`. |

### nginx (servidor del dominio de prePod)

Los chunks pesan hasta 16 MB; nginx debe permitirlos. En el `server {}` del
dominio de prePod añade (o verifica) un `location` específico:

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

Verificación rápida en el servidor: `grep -rn "client_max_body_size" /etc/nginx/`
(si el valor global ya es ≥ 20M, no hace falta el location).

## Ecosistema thePod

```
prePod (puerto 5001)          prodPod (puerto 5002)          postPod (puerto 5000)
─────────────────             ──────────────────             ──────────────────
Pre-producción:               Producción en vivo:            Post-producción:
  Branding                      Salas WebRTC (LiveKit)         Timeline multi-pista
  Kanban de episodios           Grabación por pista            Momentos y efectos
  Scripts y rundown             Soundboard                     Transcripción
  Invitados y sponsors          Chat                           Subtítulos y karaoke
  Landing + RSS                 Director de overlays           Composición multi-cámara
  Distribución                                                 Export FFmpeg
        │                              │
        └──── webhooks ────────────────┘──── webhooks ──────────────┘
              (server-to-server, X-PodPod-Secret)
```

Las tres apps comparten autenticación (`~/.podpod/users.db`) y configuración (`~/.podpod/config.json`), por lo que el login es único (SSO). Un episodio se vincula entre apps por `shared_project_id` (UUID).

## Estructura del proyecto

```
prepod/
├── app.py                 # Flask factory, media con HTTP Range, guard de acceso por podcast
├── auth.py                # Sesiones firmadas, @require_auth, reset de contraseña
├── config.py              # Paths, fuentes disponibles, policies por usuario
├── db.py                  # Schema SQLite por podcast, migraciones idempotentes
├── podcasts.py            # CRUD podcasts, hosts/directores, export/import bundle
├── branding.py            # Uploads de imágenes con Pillow
├── episodes.py            # Episodios, ideas, scripts, invitados, bloques, publish
├── templates_api.py       # Templates de rundown
├── sponsors_api.py        # Sponsors + reportes
├── landing.py             # Landing config + render público + RSS
├── distribution.py        # Panel de plataformas (Spotify/Apple/YouTube)
├── project_io.py          # Export/import de proyectos como ZIP bundle
├── integrations.py        # Webhooks con postPod/prodPod, exports
├── sounds.py              # Biblioteca de sonidos
├── rsvp.py                # RSVP público por token
├── calendar_export.py     # Export .ics
├── email_helper.py        # Emails HTML con marca (SMTP)
├── hosting.py             # Upload de media a VPS (rsync/SSH)
├── youtube_publish.py     # Upload a YouTube (OAuth Data API v3)
├── users_admin.py         # Admin de usuarios
├── shared_config.py       # ~/.podpod/config.json (SSO + secretos)
├── shared_users.py        # ~/.podpod/users.db (usuarios compartidos)
├── shared_fonts.py        # Fuentes compartidas por nombre
├── static/
│   ├── js/app.js          # SPA Vue 3 (~200 KB)
│   └── css/style.css      # Tema "Green Room" (warm-dark, azul cobalto)
├── templates/
│   ├── index.html         # Shell del SPA
│   ├── rsvp.html          # Página RSVP pública
│   └── landing/           # minimal / bold / classic (+ _base)
├── tests/                 # pytest (distribution, hosting)
├── prepod.service         # Unidad systemd (gunicorn :5001)
└── podcasts/              # Un directorio por podcast (gitignored)
    └── {slug}/
        ├── proyecto.sqlite
        ├── branding/  sponsors/  sounds/  exports/
```

## Documentación adicional

- [`ESTADO.md`](ESTADO.md) — Historial del proyecto fase por fase + cajón de mejoras pendientes

## Licencia

Proyecto privado.
