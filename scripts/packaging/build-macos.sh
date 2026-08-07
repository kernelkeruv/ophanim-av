#!/usr/bin/env bash
set -Eeuo pipefail

ARCH="${1:?expected arch (intel|arm64)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${OPHANIM_AV_VERSION:-0.1.0}"
OUT="$ROOT/dist/macos"

python -m pip install --upgrade pip
python -m pip install pyinstaller

rm -rf "$ROOT/build" "$ROOT/dist/OphanimAV" "$ROOT/dist/OphanimAV.app"
mkdir -p "$OUT"

pyinstaller \
  --noconfirm \
  --windowed \
  --name OphanimAV \
  --add-data "$ROOT/assets:assets" \
  "$ROOT/src/player.py"

APP="$ROOT/dist/OphanimAV.app"
DMG="$OUT/ophanimav-${VERSION}-macos-${ARCH}.dmg"
hdiutil create -volname "OphanimAV" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "macOS artifact:"
ls -lh "$DMG"
