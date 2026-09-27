# postPod para Mac (Apple Silicon)

App nativa (SwiftUI + AVFoundation) para la **post-producción** de postPod, pensada para gente que nunca editó video.

## Flujo

1. **Importar**: arrastra el `.zip` que exporta postPod (`export-bundle`), la carpeta con las pistas de prodPod o los videos/audios sueltos.
   - Los WebM (VP8/VP9/Opus) se convierten una sola vez a MP4 H.264 con VideoToolbox.
   - Si una pista de prodPod perdió su primer bloque (sin encabezado EBML), se repara con el encabezado de otra pista de la misma grabación.
   - Si una pista empieza tarde (timestamps absolutos), se rellena con negro/silencio para que todas queden sincronizadas.
2. **Arreglar todo**: sonido de estudio (misma cadena DSP que postPod web), transcripción local con WhisperKit, quitar silencios y muletillas. Los cortes no son destructivos.
3. **Subtítulos**: estilos predefinidos, karaoke palabra por palabra, corrección de texto y "quitar esta frase".
4. **Reels**: sugerencias con Claude (si hay API key en Ajustes) o con un análisis local. Exporta verticales 9:16 con quien habla a pantalla completa.
5. **Exportar**: YouTube 16:9, vertical 9:16, cuadrado 1:1 o solo audio MP3. Diseños: automático, quien habla, lado a lado, cuadrícula, protagonista, ventanita y arriba/abajo.

La vista previa y la exportación usan **la misma composición** (`CompositionBuilder` + `PodCompositor`), así que lo que ves es lo que sale.

## Compilar

```bash
brew install xcodegen
cd macos
zsh scripts/build-ffmpeg.sh        # una sola vez: compila ffmpeg/ffprobe en Vendor/ffmpeg (≈10 min)
xcodegen generate
open PostPodApp.xcodeproj   # o: xcodebuild -scheme PostPodApp -destination 'platform=macOS,arch=arm64' build
```

Requisitos: macOS 15+, Apple Silicon y Xcode 16 o posterior. La primera transcripción descarga el modelo de Whisper (~600 MB) a `~/Library/Application Support/postPod/whisper`.

Los proyectos se guardan en `~/Movies/postPod/<slug>/` (`project.json`, `media/`, `exports/`, `cache/`).

## Firma y contraseña guardada

Sin cuenta de Apple Developer la app va firmada "ad hoc" y su firma cambia en cada versión. El llavero de macOS ata
cada dato a la firma exacta de la app que lo guardó, así que pedía la clave de la Mac al abrir cada versión nueva.
Por eso la cuenta de thePod se guarda en `~/Library/Application Support/postPod/cuenta.dat` (permisos 0600, ofuscado,
no cifrado fuerte). Con Developer ID se podría volver al llavero.
Macs ajenas ven la app como "desarrollador no identificado" la primera vez (Privacidad y seguridad → Abrir igualmente).

Para publicar una versión en thePod: `zsh scripts/package-dmg.sh` (deja `build/postPod-<versión>.dmg` y `build/postPod.json`).

## ffmpeg dentro de la app

La app lleva su propio `ffmpeg` y `ffprobe` en `Contents/MacOS/`: el usuario no instala nada.
Los compila `scripts/build-ffmpeg.sh` desde el código fuente oficial, estáticos, arm64 y **LGPL**
(sin `--enable-gpl` ni `--enable-nonfree`), con VideoToolbox, AudioToolbox y LAME para MP3.
Las licencias quedan en `Contents/Resources/` (`FFmpeg-LGPLv2.1.txt`, `LAME-COPYING.txt`, `README.txt`).

**Versión fijada** (`FFMPEG_VERSION` en el script, hoy 9.0.2). No hace falta tener la última:
la app usa funciones que llevan años sin cambiar (decodificar WebM/VP9/Opus, filtros de audio, MP3,
H.264 por hardware). Se actualiza cuando:

- sale una corrección de seguridad que afecte a lo que usamos (demuxers de Matroska/WebM, MP4, decoders VP8/VP9/Opus/AAC), o
- necesitamos algo nuevo.

Para actualizar: cambia `FFMPEG_VERSION`, borra `Vendor/ffmpeg`, corre el script, prueba importar un paquete con WebM,
Arreglar todo y exportar video y MP3, y publica una versión nueva de la app. Si falta `Vendor/ffmpeg`, la app de desarrollo
usa el de Homebrew como respaldo.

## Prueba de punta a punta sin interfaz

```bash
postPod.app/Contents/MacOS/postPod --selftest pista1.webm pista2.webm
```

Importa, arregla, sugiere reels y exporta un 16:9, el primer reel y el MP3. Al final imprime un reporte en JSON.

## Pendiente / limitaciones conocidas

- Para distribuirla a otras Macs sin avisos de seguridad falta firmarla con un Developer ID y notarizarla.
- Todavía no se aplican los momentos/operaciones del timeline web (zoom, text_overlay, color_effect, jump_to_moment), ni los banners de sponsors ni los overlays del director.
- Whisper a veces omite las muletillas ("eh", "mmm"). Esas no se pueden cortar si no aparecen en la transcripción.
