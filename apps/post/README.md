# postPod

Editor no-destructivo de video y audio para podcast y videocast. Parte del ecosistema **thePod** (prePod → prodPod → **postPod**).

## Qué hace

postPod recibe las grabaciones de una sesión en vivo (pistas individuales por participante, efectos de sonido, capítulos, overlays del director) y permite editarlas en un timeline multi-pista sin modificar los archivos originales:

- **Timeline multi-pista** con trim, reorder, volumen per-clip y asignación de track
- **Momentos y operaciones** — marcadores con efectos: cortes, zoom, color, text overlays estilo cómic, switch de cámara, transiciones
- **Audio lane** — pista paralela para música y efectos de sonido
- **Transcripción automática** con Whisper (timestamps por palabra)
- **Editor de transcripción** — selección visual de palabras, eliminación de muletillas, edición inline
- **Subtítulos estilizados** — personalización de fuente, color, tamaño; karaoke word-by-word para vertical
- **Detección de silencios** — basada en transcript (gaps entre palabras) o FFmpeg silencedetect
- **Composición multi-cámara** — 5 layouts: lado a lado, grid 2×2, spotlight (speaker activo), PiP, solo
- **Banners CNN-style** — participantes, sponsors, temas, overlays del director
- **Speech enhancement** — highpass + denoise + EQ + compresor + loudnorm
- **10 presets de export** — YouTube (1080p/4K, 30/60fps), TikTok vertical, Instagram cuadrado, WhatsApp, Podcast MP3/M4A
- **Análisis con IA** — genera show notes y sugiere clips exportables

## Stack

| Capa | Tecnología |
|------|------------|
| Backend | Python 3.9+, Flask 3.x, Gunicorn |
| Frontend | Vue 3.5 (CDN, sin bundler), SweetAlert2 |
| Base de datos | SQLite (1 DB por proyecto, WAL mode) |
| Procesamiento | FFmpeg (composición, filtros, encoding) |
| Transcripción | faster-whisper (modelo `Systran/faster-whisper-medium`) |
| IA | Claude Sonnet vía proxy OpenAI-compatible |

## Requisitos

- Python 3.9+
- FFmpeg con libx264, aac, libmp3lame
- ~2 GB RAM mínimo (más para transcripción con Whisper)

```bash
pip install -r requirements.txt
# Opcional para transcripción:
pip install faster-whisper
# Opcional para análisis IA:
pip install openai
```

## Inicio rápido

```bash
# Desarrollo
flask --app 'app:create_app()' run --port 5000 --debug

# Producción
gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5000 --timeout 600 'app:create_app()'
```

La primera vez, se crea `~/.podpod/config.json` con claves aleatorias y `~/.podpod/users.db` con usuarios por defecto.

Abrir `http://localhost:5000` en el navegador.

## Ecosistema thePod

```
prePod (puerto 5001)          prodPod (puerto 5002)          postPod (puerto 5000)
─────────────────             ──────────────────             ──────────────────
Pre-producción:               Producción en vivo:            Post-producción:
  Branding                      Salas WebRTC (LiveKit)         Timeline multi-pista
  Kanban de episodios           Grabación por pista            Momentos y efectos
  Scripts                       Soundboard                     Transcripción
  Invitados y sponsors          Chat                           Subtítulos y karaoke
  Landing pages                 Director de overlays           Composición multi-cámara
                                                               Export FFmpeg
        │                              │
        └──── webhooks ────────────────┘──── webhooks ──────────────┘
              (server-to-server, X-PodPod-Secret)
```

Las tres apps comparten autenticación (`~/.podpod/users.db`) y configuración (`~/.podpod/config.json`).

## Estructura del proyecto

```
postpod/
├── app.py                 # Flask factory, media serving con HTTP Range
├── auth.py                # Sesiones firmadas, @require_auth
├── config.py              # Paths, presets de export, fuentes
├── db.py                  # Schema SQLite (13 tablas), migraciones idempotentes
├── exporter.py            # Pipeline FFmpeg (3100+ líneas): composición, layouts,
│                          #   karaoke, banners, speech enhancement, threading
├── files.py               # Upload/download, thumbnails, waveforms
├── timeline_api.py        # CRUD timeline, momentos, operaciones, silencios
├── captions.py            # Whisper, SRT, words.json, subtitle styles
├── integrations.py        # Webhooks server-to-server (prePod/prodPod)
├── ai_api.py / ai_engine.py  # Análisis con Claude
├── projects.py            # CRUD proyectos, participantes, sponsors
├── static/
│   ├── js/app.js          # SPA Vue 3 (19 componentes, ~5100 líneas)
│   ├── css/style.css      # Tema oscuro "broadcast booth"
│   └── fonts/             # Fuentes cómic para text overlays
├── templates/index.html   # Shell HTML
├── global/audio/          # Librería de efectos de sonido
└── projects/              # Un directorio por proyecto (gitignored)
    └── {slug}/
        ├── proyecto.json / proyecto.sqlite
        ├── media/{video,audio,image}/
        ├── exports/
        ├── branding/
        └── director_assets/
```

## Documentación adicional

- [`HANDOVER_POSTPRODUCCION.md`](HANDOVER_POSTPRODUCCION.md) — Documento técnico completo (1000+ líneas) para portar post-producción a app nativa macOS: schema, endpoints, pipeline FFmpeg, puntos frágiles
- [`ESTADO.md`](ESTADO.md) — Estado del proyecto fase por fase

## Licencia

Proyecto privado.
