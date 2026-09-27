#!/bin/bash
# Deja la última versión de postPod para Mac donde la sirve /descargas.
# El .dmg se publica en la rama "releases" del repo (solo contiene la última versión).
#   bash scripts/publish-postpod-mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=$(python3 -c 'from shared_config import load_shared_config as l; from pathlib import Path; print(l().get("downloads_dir") or Path.home()/".podpod"/"downloads")')
mkdir -p "$DEST"
git fetch -q origin releases
git show origin/releases:postPod.dmg  > "$DEST/postPod.dmg.tmp"
git show origin/releases:postPod.json > "$DEST/postPod.json.tmp"
EXPECTED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$DEST/postPod.json.tmp")
ACTUAL=$(sha256sum "$DEST/postPod.dmg.tmp" | cut -d' ' -f1)
[ "$EXPECTED" = "$ACTUAL" ] || { echo "el .dmg no coincide con su ficha"; rm -f "$DEST"/*.tmp; exit 1; }
mv "$DEST/postPod.dmg.tmp" "$DEST/postPod.dmg"
mv "$DEST/postPod.json.tmp" "$DEST/postPod.json"
echo "OK: $(cat "$DEST/postPod.json")"
