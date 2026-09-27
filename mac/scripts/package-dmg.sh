#!/bin/zsh
# Compila thePod en Release y arma el .dmg para descargar desde thePod.
#   zsh scripts/package-dmg.sh      → build/thePod-<versión>.dmg y build/thePod.json
# Sin firma de Apple Developer: la primera vez cada Mac debe autorizarla (ver /descargas en thePod).
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
zsh scripts/build-ffmpeg.sh >/dev/null
xcodegen generate -q >/dev/null 2>&1
xcodebuild -project PostPodApp.xcodeproj -scheme PostPodApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build.noindex/dd-release build > build/release.log 2>&1 \
  || { grep -E "error:" build/release.log | head; exit 1; }
APP=build.noindex/dd-release/Build/Products/Release/thePod.app
# Que las copias de compilación no aparezcan como apps en la Mac (solo la de Aplicaciones)
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister() { "$LSREG" -u "$1" 2>/dev/null || true; }
unregister "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
STAGE=build.noindex/dmg-stage
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/thePod.app"
ln -s /Applications "$STAGE/Aplicaciones"
DMG=build/thePod-$VERSION.dmg
rm -f "$DMG"
hdiutil create -volname "thePod $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
unregister "$STAGE/thePod.app"
rm -rf "$STAGE"
SIZE=$(stat -f %z "$DMG")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
printf '{"version": "%s", "build": "%s", "size": %s, "sha256": "%s", "date": "%s", "min_macos": "15.0"}\n' \
  "$VERSION" "$BUILD" "$SIZE" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/thePod.json
echo "OK $DMG ($((SIZE/1048576)) MB)"
cat build/thePod.json
