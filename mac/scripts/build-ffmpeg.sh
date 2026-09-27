#!/bin/zsh
# Compila ffmpeg estático (arm64, LGPL) para meterlo dentro de thePod.app.
# Versión fijada a propósito: la app se prueba con esta versión. Para actualizar, cambia
# FFMPEG_VERSION, corre este script, prueba importar/arreglar/exportar y publica la app nueva.
#
#   zsh scripts/build-ffmpeg.sh          # deja los binarios en Vendor/ffmpeg/
#
# Solo usa lo que trae macOS + Xcode (clang, make, curl). No usa Homebrew.
set -euo pipefail

FFMPEG_VERSION=9.0.2
LAME_VERSION=3.100
MIN_MACOS=15.0

ROOT=${0:A:h:h}
WORK="$ROOT/build/ffmpeg-src"
DEPS="$WORK/deps"
OUT="$ROOT/Vendor/ffmpeg"
LIC="$ROOT/Vendor/licenses"
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
CFLAGS_COMMON="-arch arm64 -mmacosx-version-min=$MIN_MACOS -O2"

rm -f "$OUT/ffprobe"      # ya no se usa: la app lee los tiempos con ffmpeg (menos peso)
if [[ -x "$OUT/ffmpeg" ]] && "$OUT/ffmpeg" -version 2>/dev/null | head -1 | grep -q "version $FFMPEG_VERSION "; then
  echo "ffmpeg $FFMPEG_VERSION ya está en Vendor/ffmpeg"; exit 0
fi

mkdir -p "$WORK" "$DEPS" "$OUT" "$LIC"
cd "$WORK"

# --- LAME (MP3, LGPL) ---
if [[ ! -f "$DEPS/lib/libmp3lame.a" ]]; then
  [[ -f lame-$LAME_VERSION.tar.gz ]] || curl -fsSL -o lame-$LAME_VERSION.tar.gz \
    "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
  rm -rf lame-$LAME_VERSION && tar xzf lame-$LAME_VERSION.tar.gz
  cd lame-$LAME_VERSION
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym      # símbolo inexistente que rompe el link en macOS
  ./configure --prefix="$DEPS" --host=aarch64-apple-darwin --enable-static --disable-shared \
    --disable-frontend --disable-dependency-tracking CFLAGS="$CFLAGS_COMMON" >/dev/null
  make -j$JOBS >/dev/null && make install >/dev/null
  cp COPYING "$LIC/LAME-COPYING.txt"
  cd "$WORK"
fi

# --- FFmpeg (LGPL: sin --enable-gpl ni --enable-nonfree) ---
[[ -f ffmpeg-$FFMPEG_VERSION.tar.xz ]] || curl -fsSL -o ffmpeg-$FFMPEG_VERSION.tar.xz \
  "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
rm -rf ffmpeg-$FFMPEG_VERSION && tar xJf ffmpeg-$FFMPEG_VERSION.tar.xz
cd ffmpeg-$FFMPEG_VERSION
./configure --prefix="$WORK/install" --arch=arm64 --target-os=darwin --cc=clang \
  --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay --disable-ffprobe \
  --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-pthreads \
  --enable-libmp3lame --disable-network \
  --extra-cflags="$CFLAGS_COMMON -I$DEPS/include" \
  --extra-ldflags="-arch arm64 -mmacosx-version-min=$MIN_MACOS -L$DEPS/lib" >/dev/null
make -j$JOBS >/dev/null
cp ffmpeg "$OUT/"
strip "$OUT/ffmpeg"
cp COPYING.LGPLv2.1 "$LIC/FFmpeg-LGPLv2.1.txt"
cp LICENSE.md "$LIC/FFmpeg-LICENSE.md"
printf 'FFmpeg %s (https://ffmpeg.org) bajo LGPL 2.1, compilado sin componentes GPL.\nCódigo fuente: https://ffmpeg.org/releases/ffmpeg-%s.tar.xz\nLAME %s (https://lame.sourceforge.io) bajo LGPL.\n' \
  $FFMPEG_VERSION $FFMPEG_VERSION $LAME_VERSION > "$LIC/README.txt"

echo "OK: $("$OUT/ffmpeg" -version | head -1)"
otool -L "$OUT/ffmpeg" | tail -n +2 | awk '{print "  enlaza: " $1}'
ls -lh "$OUT"
