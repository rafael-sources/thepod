# thePod para Mac (Apple Silicon)

App nativa (SwiftUI + AVFoundation) con toda la suite: **pre** (prePod), **prod** (prodPod), **ama** (amaPod) y **post**,
la post-producción, pensada para gente que nunca editó video. Versión actual: la de `MARKETING_VERSION` en `project.yml`.

El manual de uso completo (pantalla por pantalla) está en la web de thePod: `/docs/postpodapp` (Funcionalidades, Atajos, Conceptos, FAQ).
Este README es para quien compila y mantiene la app.

## Qué hace post (resumen)

Barra lateral en tres bloques; cada sección tiene un «?» con ayuda y atajos.

- **Preparar**: Grabación (personas, nombres, guion y sponsors de prePod) · Limpiar sonido (cadena DSP de estudio, silencios,
  muletillas, EQ de tres bandas, Voz pareja = compresor, Menos siseo = de-esser) · Subtítulos (WhisperKit local, estilos, karaoke,
  corrección por frase que conserva los tiempos de las palabras que no cambian; «Ajustar al audio» = `SubtitleSync`: corre cada
  frase a donde suena el micrófono de esa persona y recorta palabras estiradas sobre pausas; «Volver a escuchar» el episodio
  o solo un reel → `Reel.words`, texto propio del reel) · Palabras sensibles (groserías y temas delicados: pitido encima en todas las pistas y/o subtítulo con eufemismo).
- **Armar**: Aspecto (diseños de cámaras, fondo virtual con Vision, color, marca, intro/cierre) · Textos, stickers y b-roll
  (pantalla completa o ventanita que respeta aspecto y `preferredTransform`) · Música y efectos (soundboard, archivos, voz
  artificial con AVSpeechSynthesizer, ducking, bucle) · Cintillos (Noticiero, Limpio, Sponsor; animación y whoosh) · Patrocinios y marcas.
- **Mezcla** (no es sección: vive en el timeline): ondas por persona, S/M, medidor, volumen dibujado (puntos dB con rampas lineales),
  «Silenciar solo a X» / «−6 dB a X» por trozo, −16 LUFS al exportar, pistas WAV por separado.
- **Entregar**: Reels por pestañas (Diseño, Subtítulos, Música, B-roll, Cintillos; plantillas en
  `~/Library/Application Support/postPod/plantillas-reel.json`) · Exportar (16:9, 9:16, 1:1, MP3; H.264 o HEVC) · Publicar vía prePod.
- Reloj grande + `TimecodeField` en todos los campos de tiempo; deshacer/rehacer (120 pasos); atajos (espacio/K, J/L, flechas, M, I, O, ⌘Z).

Los tiempos de Whisper por palabra salen adelantados (medido: 0,1–0,45 s, a veces 0,8 s) y a veces una palabra se estira
sobre una pausa. Por eso toda transcripción nueva pasa por `SubtitleSync.align`, y los proyectos viejos muestran el aviso
«pueden aparecer un poco antes» hasta que se ajustan (`Project.wordsSynced`). Prueba sin ventana: `thePod --sync-test <proyecto> [--listen]`.

La vista previa y la exportación usan **la misma composición** (`CompositionBuilder` + `PodCompositor`): lo que ves es lo que sale.
Las capas, b-roll, cintillos y sponsors fuera de la ventana exportada (reel o trozo) no entran (`CompositionBuilder.outputStart`).

## Dónde está cada cosa (Sources/)

| Carpeta | Qué hay |
|---|---|
| `App/` | `AppModel`, `SessionExtras` (historial de deshacer, atajos, plantillas de reel, ayuda, mezcla, palabras sensibles, volumen dibujado), `BrandKit` (logos e intro) |
| `Models/` | `Project` (lanes, cortes, capas, cintillos, reels, `VolumePoint`, `VoiceEQ`, `sensitive`) |
| `Services/` | DSP, WhisperKit, `SensitiveWords`, energía/quién habla, Vision (fondo virtual), API de thePod |
| `Render/` | `CompositionBuilder`, `PodCompositor`, `Exporter` (video, MP3, stems WAV) |
| `Views/` | `ProjectView` (vista previa, reloj, paneles), `EpisodeTimeline`, `Steps` (secciones), `SensitiveStep`, `Timecode` |
| `PrePod/`, `ProdPod/`, `AmaPod/` | las otras tres secciones (prod incluye `ProdTeleprompter`) |

## Compilar

```bash
brew install xcodegen
cd macos
zsh scripts/build-ffmpeg.sh        # una sola vez: compila ffmpeg en Vendor/ffmpeg (≈10 min)
xcodegen generate
open PostPodApp.xcodeproj   # o: xcodebuild -scheme PostPodApp -destination 'platform=macOS,arch=arm64' build
```

Requisitos: macOS 15+, Apple Silicon y Xcode 16 o posterior. La primera transcripción descarga el modelo de Whisper (~600 MB) a `~/Library/Application Support/postPod/whisper`.

Los proyectos se guardan en `~/Movies/postPod/<slug>/` (`project.json`, `media/`, `exports/`, `cache/`). Las grabaciones de la sala,
en `~/Library/Application Support/postPod/grabaciones/`.

## Publicar una versión

1. Sube `MARKETING_VERSION` en `project.yml` (función nueva: minor; arreglo: patch).
2. `zsh scripts/package-dmg.sh` deja `build/thePod-<versión>.dmg` y `build/thePod.json` (tamaño, sha256, fecha, min_macos).
3. En el repo `thepod`, rama `releases` (solo contiene la última versión): reemplaza `thePod.dmg` y `thePod.json`, commit «release X (build N)», push.
4. En el servidor: `bash scripts/publish-thepod-mac.sh` (verifica el sha256 y lo deja donde lo sirve `/descargas`).
5. Notas de versión: doc «thePod para Mac · Notas de versión»; manual: doc «thePod para Mac · Manual» y `thepod/templates/docs/postpodapp/`.

La app busca actualizaciones al abrir (y en Ajustes → Buscar ahora), verifica el sha256 y reemplaza al reiniciar.

## Firma y contraseña guardada

Sin cuenta de Apple Developer la app va firmada "ad hoc" y su firma cambia en cada versión. El llavero de macOS ata
cada dato a la firma exacta de la app que lo guardó, así que pedía la clave de la Mac al abrir cada versión nueva.
Por eso la cuenta de thePod se guarda en `~/Library/Application Support/postPod/cuenta.dat` (permisos 0600, ofuscado,
no cifrado fuerte). Con Developer ID se podría volver al llavero.
Macs ajenas ven la app como "desarrollador no identificado" la primera vez (Privacidad y seguridad → Abrir igualmente),
y los permisos de cámara y micrófono se vuelven a pedir en cada versión.

## ffmpeg dentro de la app

La app lleva su propio `ffmpeg` en `Contents/MacOS/`: el usuario no instala nada.
Los compila `scripts/build-ffmpeg.sh` (sin ffprobe: los tiempos de inicio se leen con ffmpeg) desde el código fuente oficial, estáticos, arm64 y **LGPL**
(sin `--enable-gpl` ni `--enable-nonfree`), con VideoToolbox, AudioToolbox y LAME para MP3.
Las licencias quedan en `Contents/Resources/` (`FFmpeg-LGPLv2.1.txt`, `LAME-COPYING.txt`, `README.txt`).

**Versión fijada** (`FFMPEG_VERSION` en el script, hoy 9.0.2). Se actualiza cuando sale una corrección de seguridad que afecte
a lo que usamos (demuxers de Matroska/WebM, MP4, decoders VP8/VP9/Opus/AAC) o cuando necesitamos algo nuevo.
Para actualizar: cambia `FFMPEG_VERSION`, borra `Vendor/ffmpeg`, corre el script, prueba importar un paquete con WebM,
Limpiar sonido y exportar video y MP3, y publica una versión nueva. Si falta `Vendor/ffmpeg`, la app de desarrollo
usa el de Homebrew como respaldo.

## Pruebas sin interfaz (CLI)

Todas se corren con el binario de la app (`thePod.app/Contents/MacOS/thePod`), con `<slug>` = carpeta en `~/Movies/postPod/`:

| Comando | Qué hace |
|---|---|
| `--selftest p1.webm p2.webm` | importa, arregla, crea reels y exporta 16:9, primer reel y MP3; imprime un JSON |
| `--render <slug> <inicio> <fin> <landscape\|vertical\|square\|audio> [reel N]` | exporta una ventana del episodio (o un reel) a `exports/` |
| `--post-snapshot`, `--pre-snapshot`, `--intro-snapshot` | capturas de pantalla de la interfaz (sin ventana real) |
| `--extras-test <slug>`, `--sensitive-test <slug>`, `--stems-test <slug>` | prueban capas/b-roll, palabras sensibles y pistas WAV |
| `--frame-test <slug> <reel> <seg> <png> [--crowd] [--capbottom] [--bgpodcast]` | un cuadro de un reel en 9:16 (con un cintillo y un texto de más, subtítulos en su lugar, fondo del podcast) |
| `--meter-test <slug>`, `--sync-test <slug> [--listen]` | medidor con el volumen aplicado; subtítulos ajustados a la voz |
| `--brand-kit <carpeta>`, `--intro-frames <carpeta> <w> <h> <0\|1\|2>` | generan el set de marca y los cuadros de la intro |

Con `THEPOD_DEBUG=1` el render imprime por `NSLog` el volumen base de cada pista, los puntos de envolvente y las pistas de audio de la mezcla.
Para medir resultados: `ffmpeg -af astats`/`volumedetect` sobre lo exportado (ver notas de versión para los umbrales usados).

## Pendiente / limitaciones conocidas

- Para distribuirla a otras Macs sin avisos de seguridad falta firmarla con un Developer ID y notarizarla.
- El teleprompter encadenado («después del anterior») sale a la hora calculada; no reacciona al final real del anterior.
- Acomodo en 9:16 y 1:1 (`RenderScene.arrangement` + `FrameLayout`): lo automático (subtítulos, sponsors, b-roll en ventanita,
  cintillos, nombres) se corre en vertical para no pisar el logo, las capas ni los subtítulos arrastrados (que no se mueven).
  Si no hay lugar libre, queda donde iba. En 16:9 sigue la regla vieja (los subtítulos suben sobre el cintillo).
- Fondo virtual: máscara con suavizado que sigue el movimiento y reusa la anterior si Vision falla un cuadro; «Fondo del
  podcast» se recorta en pantalla sobre el mismo fondo de los recuadros. El parpadeo no está medido con números, solo visto.
- Medidor por persona: reproduciendo, `LevelTap` (MTAudioProcessingTap) + la curva de volumen de la mezcla (el tap escucha
  ANTES del volumen de `AVAudioMixInputParameters`: medido con `--meter-test`, −11 dB al bajar a 25 %); en pausa, estimación.
- Whisper a veces omite las muletillas ("eh", "mmm"); esas no se pueden cortar si no aparecen en la transcripción.
- Probado sin ratón (capturas y renders medidos con ffmpeg); el arrastre de puntos de volumen, el menú de plantillas y los atajos en ventana real no se probaron a mano.
