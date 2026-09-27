#!/bin/zsh
# Compila postPod en Release y arma el .dmg para descargar desde thePod.
#   zsh scripts/package-dmg.sh      → build/postPod-<versión>.dmg y build/postPod.json
# Sin firma de Apple Developer: la primera vez cada Mac debe autorizarla (ver /descargas en thePod).
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
zsh scripts/build-ffmpeg.sh >/dev/null
xcodegen generate -q >/dev/null 2>&1
xcodebuild -project PostPodApp.xcodeproj -scheme PostPodApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd-release build > build/release.log 2>&1 \
  || { grep -E "error:" build/release.log | head; exit 1; }
APP=build/dd-release/Build/Products/Release/postPod.app
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
STAGE=build/dmg-stage
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/postPod.app"
ln -s /Applications "$STAGE/Aplicaciones"
DMG=build/postPod-$VERSION.dmg
rm -f "$DMG"
hdiutil create -volname "postPod $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
SIZE=$(stat -f %z "$DMG")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
printf '{"version": "%s", "build": "%s", "size": %s, "sha256": "%s", "date": "%s", "min_macos": "15.0"}\n' \
  "$VERSION" "$BUILD" "$SIZE" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/postPod.json
echo "OK $DMG ($((SIZE/1048576)) MB)"
cat build/postPod.json
