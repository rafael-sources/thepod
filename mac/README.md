# thePod for Mac (Apple Silicon)

Native app (SwiftUI + AVFoundation) with the whole suite: **pre** (prePod), **prod** (prodPod), **ama** (amaPod) and **post**,
the post-production, designed for people who have never edited video. Current version: the one in `MARKETING_VERSION` in `project.yml`.

The full user manual (screen by screen) is on thePod's website: `/docs/postpodapp` (Features, Shortcuts, Concepts, FAQ).
This README is for whoever builds and maintains the app.

## What post does (summary)

Sidebar in three blocks; each section has a «?» with help and shortcuts.

- **Prepare** (Preparar): Recording (people, names, script and sponsors from prePod) · Clean up sound (studio DSP chain, silences,
  filler words, three-band EQ, Voz pareja = compressor, Menos siseo = de-esser) · Subtitles (local WhisperKit, styles, karaoke,
  per-phrase correction that keeps the timings of unchanged words; «Ajustar al audio» = `SubtitleSync`: shifts each
  phrase to where that person's microphone sounds and trims words stretched over pauses; «Volver a escuchar» the episode
  or just a reel → `Reel.words`, the reel's own text) · Sensitive words (profanity and sensitive topics: beep on top in every track and/or subtitle with a euphemism).
- **Build** (Armar): Look (camera layouts, virtual background with Vision, color, branding, intro/outro) · Texts, stickers and b-roll
  (full screen or a small window respecting aspect and `preferredTransform`) · Music and effects (soundboard, files, synthetic
  voice with AVSpeechSynthesizer, ducking, loop) · Lower thirds (Noticiero, Limpio, Sponsor; animation and whoosh) · Sponsorships and brands.
- **Mix** (not a section: it lives in the timeline): waveforms per person, S/M, meter, drawn volume (dB points with linear ramps),
  «Silenciar solo a X» / «−6 dB a X» per span, −16 LUFS on export, separate WAV stems.
- **Deliver** (Entregar): Reels in tabs (Design, Subtitles, Music, B-roll, Lower thirds; templates in
  `~/Library/Application Support/postPod/plantillas-reel.json`) · Export (16:9, 9:16, 1:1, MP3; H.264 or HEVC) · Publish via prePod.
- Large clock + `TimecodeField` in every time field; undo/redo (120 steps); shortcuts (space/K, J/L, arrows, M, I, O, ⌘Z).

Whisper's per-word timings come out early (measured: 0.1–0.45 s, sometimes 0.8 s) and sometimes a word is stretched
over a pause. That's why every new transcript goes through `SubtitleSync.align`, and old projects show the notice
«pueden aparecer un poco antes» until they're aligned (`Project.wordsSynced`). Windowless test: `thePod --sync-test <project> [--listen]`.

The preview and the export use **the same composition** (`CompositionBuilder` + `PodCompositor`): what you see is what comes out.
Layers, b-roll, lower thirds and sponsors outside the exported window (reel or chunk) are left out (`CompositionBuilder.outputStart`).

## Where everything is (Sources/)

| Folder | What's there |
|---|---|
| `App/` | `AppModel`, `SessionExtras` (undo history, shortcuts, reel templates, help, mix, sensitive words, drawn volume), `BrandKit` (logos and intro) |
| `Models/` | `Project` (lanes, cuts, layers, lower thirds, reels, `VolumePoint`, `VoiceEQ`, `sensitive`) |
| `Services/` | DSP, WhisperKit, `SensitiveWords`, energy/who's speaking, Vision (virtual background), thePod API |
| `Render/` | `CompositionBuilder`, `PodCompositor`, `Exporter` (video, MP3, WAV stems) |
| `Views/` | `ProjectView` (preview, clock, panels), `EpisodeTimeline`, `Steps` (sections), `SensitiveStep`, `Timecode` |
| `PrePod/`, `ProdPod/`, `AmaPod/` | the other three sections (prod includes `ProdTeleprompter`) |

## Building

```bash
brew install xcodegen
cd macos
zsh scripts/build-ffmpeg.sh        # only once: builds ffmpeg into Vendor/ffmpeg (≈10 min)
xcodegen generate
open PostPodApp.xcodeproj   # or: xcodebuild -scheme PostPodApp -destination 'platform=macOS,arch=arm64' build
```

Requirements: macOS 15+, Apple Silicon and Xcode 16 or later. The first transcription downloads the Whisper model (~600 MB) to `~/Library/Application Support/postPod/whisper`.

Projects are saved in `~/Movies/postPod/<slug>/` (`project.json`, `media/`, `exports/`, `cache/`). Room recordings,
in `~/Library/Application Support/postPod/grabaciones/`.

## Publishing a version

1. Bump `MARKETING_VERSION` in `project.yml` (new feature: minor; fix: patch).
2. `zsh scripts/package-dmg.sh` leaves `build/thePod-<version>.dmg` and `build/thePod.json` (size, sha256, date, min_macos).
3. In the `thepod` repo, `releases` branch (it only contains the latest version): replace `thePod.dmg` and `thePod.json`, commit «release X (build N)», push.
4. On the server: `bash scripts/publish-thepod-mac.sh` (verifies the sha256 and puts it where `/descargas` serves it).
5. Release notes: doc «thePod para Mac · Notas de versión»; manual: doc «thePod para Mac · Manual» and `thepod/templates/docs/postpodapp/`.

The app checks for updates on launch (and in Settings → Buscar ahora), verifies the sha256 and replaces itself on restart.

## Signing and saved password

Without an Apple Developer account the app is signed "ad hoc" and its signature changes with every version. The macOS keychain ties
each item to the exact signature of the app that saved it, so it asked for the Mac's password when opening each new version.
That's why the thePod account is saved in `~/Library/Application Support/postPod/cuenta.dat` (0600 permissions, obfuscated,
not strong encryption). With a Developer ID the keychain could be used again.
Other Macs see the app as "unidentified developer" the first time (Privacy & Security → Open Anyway),
and camera and microphone permissions are requested again with each version.

## ffmpeg inside the app

The app carries its own `ffmpeg` in `Contents/MacOS/`: the user installs nothing.
`scripts/build-ffmpeg.sh` builds it (without ffprobe: start times are read with ffmpeg) from the official source code, static, arm64 and **LGPL**
(no `--enable-gpl` or `--enable-nonfree`), with VideoToolbox, AudioToolbox and LAME for MP3.
The licenses go into `Contents/Resources/` (`FFmpeg-LGPLv2.1.txt`, `LAME-COPYING.txt`, `README.txt`).

**Pinned version** (`FFMPEG_VERSION` in the script, currently 9.0.2). It's updated when a security fix comes out that affects
what we use (Matroska/WebM and MP4 demuxers, VP8/VP9/Opus/AAC decoders) or when we need something new.
To update: change `FFMPEG_VERSION`, delete `Vendor/ffmpeg`, run the script, test importing a bundle with WebM,
Limpiar sonido and exporting video and MP3, and publish a new version. If `Vendor/ffmpeg` is missing, the development app
falls back to Homebrew's.

## Headless tests (CLI)

All run with the app binary (`thePod.app/Contents/MacOS/thePod`), with `<slug>` = folder in `~/Movies/postPod/`:

| Command | What it does |
|---|---|
| `--selftest p1.webm p2.webm` | imports, fixes, creates reels and exports 16:9, first reel and MP3; prints a JSON |
| `--render <slug> <start> <end> <landscape\|vertical\|square\|audio> [reel N]` | exports a window of the episode (or a reel) to `exports/` |
| `--post-snapshot`, `--pre-snapshot`, `--intro-snapshot` | UI screenshots (no real window) |
| `--extras-test <slug>`, `--sensitive-test <slug>`, `--stems-test <slug>` | test layers/b-roll, sensitive words and WAV stems |
| `--frame-test <slug> <reel> <sec> <png> [--crowd] [--capbottom] [--bgpodcast]` | one frame of a reel in 9:16 (with an extra lower third and text, subtitles in their place, podcast background) |
| `--meter-test <slug>`, `--sync-test <slug> [--listen]` | meter with the volume applied; subtitles aligned to the voice |
| `--brand-kit <folder>`, `--intro-frames <folder> <w> <h> <0\|1\|2>` | generate the brand set and the intro frames |

With `THEPOD_DEBUG=1` the render prints via `NSLog` each track's base volume, the envelope points and the mix's audio tracks.
To measure results: `ffmpeg -af astats`/`volumedetect` on the exported file (see the release notes for the thresholds used).

## Pending / known limitations

- To distribute it to other Macs without security warnings it still needs to be signed with a Developer ID and notarized.
- Arrangement in 9:16 and 1:1 (`RenderScene.arrangement` + `FrameLayout`): automatic items (subtitles, sponsors, PiP b-roll,
  lower thirds, names) shift vertically so as not to cover the logo, layers or dragged subtitles (which don't move).
  If there's no free spot, it stays where it was. In 16:9 the old rule still applies (subtitles move up above the lower third).
- Virtual background: smoothed mask that follows motion and reuses the previous one if Vision fails on a frame; «Fondo del
  podcast» is cut out on screen over the same background as the boxes. Flicker hasn't been measured with numbers, only seen.
- Per-person meter: while playing, `LevelTap` (MTAudioProcessingTap) + the mix volume curve (the tap listens
  BEFORE the `AVAudioMixInputParameters` volume: measured with `--meter-test`, −11 dB when lowering to 25 %); when paused, an estimate.
- Whisper sometimes omits filler words ("eh", "mmm"); those can't be cut if they don't appear in the transcript.
- Tested without a mouse (screenshots and renders measured with ffmpeg); dragging volume points, the templates menu and shortcuts in a real window weren't tested by hand.
