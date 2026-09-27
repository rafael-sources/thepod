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
brew install xcodegen ffmpeg
cd macos
xcodegen generate
open PostPodApp.xcodeproj   # o: xcodebuild -scheme PostPodApp -destination 'platform=macOS,arch=arm64' build
```

Requisitos: macOS 15+, Apple Silicon y Xcode 16 o posterior. La primera transcripción descarga el modelo de Whisper (~600 MB) a `~/Library/Application Support/postPod/whisper`.

Los proyectos se guardan en `~/Movies/postPod/<slug>/` (`project.json`, `media/`, `exports/`, `cache/`).

## Prueba de punta a punta sin interfaz

```bash
postPod.app/Contents/MacOS/postPod --selftest pista1.webm pista2.webm
```

Importa, arregla, sugiere reels y exporta un 16:9, el primer reel y el MP3. Al final imprime un reporte en JSON.

## Pendiente / limitaciones conocidas

- ffmpeg se toma de Homebrew. Para distribuirla a otras Macs hay que empaquetar un binario de ffmpeg dentro de `Contents/Resources/bin/`, y firmarla y notarizarla.
- Todavía no se aplican los momentos/operaciones del timeline web (zoom, text_overlay, color_effect, jump_to_moment), ni los banners de sponsors ni los overlays del director.
- Whisper a veces omite las muletillas ("eh", "mmm"). Esas no se pueden cortar si no aparecen en la transcripción.
