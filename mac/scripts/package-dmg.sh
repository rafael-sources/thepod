#!/bin/zsh
# Compila thePod en Release y arma el .dmg para descargar desde thePod.
#   zsh scripts/package-dmg.sh      → build/thePod-<versión>.dmg y build/thePod.json
# Si en el Llavero está el certificado «Developer ID Application» y el perfil de notarización «thepod-notario»
# (xcrun notarytool store-credentials thepod-notario …), la app sale firmada y notarizada por Apple: se abre
# sin avisos de seguridad. Si no, sale con la firma local de antes (cada Mac debe autorizarla la primera vez).
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
zsh scripts/build-ffmpeg.sh >/dev/null
xcodegen generate -q >/dev/null 2>&1
xcodebuild -project PostPodApp.xcodeproj -scheme PostPodApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build.noindex/dd-release CURRENT_PROJECT_VERSION=$(date +%Y%m%d%H%M) build > build/release.log 2>&1 \
  || { grep -E "error:" build/release.log | head; exit 1; }
APP=build.noindex/dd-release/Build/Products/Release/thePod.app
# Que las copias de compilación no aparezcan como apps en la Mac (solo la de Aplicaciones)
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister() { "$LSREG" -u "$1" 2>/dev/null || true; }
unregister "$APP"
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)
NOTARY=thepod-notario
SIGNED=0
if [[ -n "$IDENTITY" ]]; then
  # De adentro hacia afuera: frameworks, ffmpeg y al final la app con sus permisos (cámara y micrófono)
  sign() { codesign --force --options runtime --timestamp -s "$IDENTITY" "$@"; }
  for fw in "$APP"/Contents/Frameworks/*.framework(N); do sign "$fw"; done
  for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do sign "$dylib"; done
  sign "$APP/Contents/MacOS/ffmpeg"
  sign --entitlements thePod.entitlements "$APP"
  codesign --verify --deep --strict "$APP"
  SIGNED=1
  if xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    # Apple revisa la app (unos minutos) y se le pega el comprobante para que abra sin internet
    ZIP=build.noindex/thePod-notarizar.zip
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY" --wait > build/notary-app.log 2>&1 \
      || { cat build/notary-app.log; exit 1; }
    grep -q "status: Accepted" build/notary-app.log || { cat build/notary-app.log; exit 1; }
    xcrun stapler staple "$APP" >/dev/null
    rm -f "$ZIP"
    SIGNED=2
  fi
fi
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
if [[ $SIGNED -ge 1 ]]; then codesign --force --timestamp -s "$IDENTITY" "$DMG"; fi
if [[ $SIGNED -eq 2 ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait > build/notary-dmg.log 2>&1 \
    || { cat build/notary-dmg.log; exit 1; }
  grep -q "status: Accepted" build/notary-dmg.log || { cat build/notary-dmg.log; exit 1; }
  xcrun stapler staple "$DMG" >/dev/null
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | head -2
fi
SIZE=$(stat -f %z "$DMG")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
printf '{"version": "%s", "build": "%s", "size": %s, "sha256": "%s", "date": "%s", "min_macos": "15.0"}\n' \
  "$VERSION" "$BUILD" "$SIZE" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/thePod.json
echo "OK $DMG ($((SIZE/1048576)) MB) · firma: $([[ $SIGNED -eq 2 ]] && echo "Developer ID + notarizada" || ([[ $SIGNED -eq 1 ]] && echo "Developer ID sin notarizar" || echo "local"))"
cat build/thePod.json
