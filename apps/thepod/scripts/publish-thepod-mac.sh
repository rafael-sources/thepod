#!/bin/bash
# Deja la última versión de thePod para Mac donde la sirve /descargas.
# Fuentes, por orden: 1) ~/.podpod/incoming/ (copiada a mano por scp cuando GitHub no recibe el .dmg),
# 2) la rama "releases" del repo. Nunca se degrada: solo se instala una versión mayor que la servida.
#   bash scripts/publish-thepod-mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=$(python3 -c 'from shared_config import load_shared_config as l; from pathlib import Path; print(l().get("downloads_dir") or Path.home()/".podpod"/"downloads")')
INCOMING="$HOME/.podpod/incoming"
mkdir -p "$DEST"

ver() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","0"))' "$1" 2>/dev/null || echo 0; }
newer() { python3 -c 'import sys
def k(v): return tuple(int(x) for x in v.split(".") if x.isdigit())
sys.exit(0 if k(sys.argv[1]) > k(sys.argv[2]) else 1)' "$1" "$2"; }
install() {  # $1 dmg  $2 json  $3 origen
  local expected actual
  expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$2")
  actual=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$expected" = "$actual" ] || { echo "$3: el .dmg no coincide con su ficha"; return 1; }
  mv "$1" "$DEST/thePod.dmg"
  mv "$2" "$DEST/thePod.json"
  echo "OK ($3): $(cat "$DEST/thePod.json")"
}

CURRENT=$(ver "$DEST/thePod.json")

# 1) Copia local completa (los .tmp son transferencias a medias: no se tocan)
if [ -f "$INCOMING/thePod.dmg" ] && [ -f "$INCOMING/thePod.json" ]; then
  V=$(ver "$INCOMING/thePod.json")
  if newer "$V" "$CURRENT"; then
    install "$INCOMING/thePod.dmg" "$INCOMING/thePod.json" "incoming" && exit 0
  else
    rm -f "$INCOMING/thePod.dmg" "$INCOMING/thePod.json"
  fi
fi

# 2) GitHub, rama releases
git fetch -q origin releases
git show origin/releases:thePod.json > "$DEST/thePod.json.tmp"
V=$(ver "$DEST/thePod.json.tmp")
if ! newer "$V" "$CURRENT"; then rm -f "$DEST/thePod.json.tmp"; exit 0; fi
git show origin/releases:thePod.dmg > "$DEST/thePod.dmg.tmp"
install "$DEST/thePod.dmg.tmp" "$DEST/thePod.json.tmp" "releases" || { rm -f "$DEST/thePod.dmg.tmp" "$DEST/thePod.json.tmp"; exit 1; }
