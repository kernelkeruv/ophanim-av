#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${OPHANIM_AV_VERSION:-0.1.0}"
OUT="$ROOT/dist/linux"
STAGE="$ROOT/dist/linux-stage"
APP_DIR="/opt/ophanim-av"

rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE$APP_DIR" "$STAGE/usr/bin" "$STAGE/usr/share/applications"

sudo apt-get update
sudo apt-get install -y ruby ruby-dev rpm zstd
sudo gem install --no-document fpm

cp -a "$ROOT/src" "$STAGE$APP_DIR/"
cp -a "$ROOT/scripts" "$STAGE$APP_DIR/"
cp -a "$ROOT/systemd" "$STAGE$APP_DIR/"
cp -a "$ROOT/config" "$STAGE$APP_DIR/"
cp -a "$ROOT/assets" "$STAGE$APP_DIR/"
cp "$ROOT/requirements.in" "$ROOT/requirements.lock.txt" "$ROOT/README.md" "$STAGE$APP_DIR/"

install -m 0755 "$ROOT/scripts/launchers/ophanim-player" "$STAGE/usr/bin/ophanim-player"
install -m 0755 "$ROOT/scripts/launchers/ophanim-index" "$STAGE/usr/bin/ophanim-index"
install -m 0644 "$ROOT/desktop/ophanim-av-player.desktop" "$STAGE/usr/share/applications/ophanim-av-player.desktop"

fpm -s dir -t deb -n ophanim-av -v "$VERSION" --iteration 1 --prefix / -C "$STAGE" \
  -p "$OUT/ophanim-av_${VERSION}_amd64.deb" .
fpm -s dir -t rpm -n ophanim-av -v "$VERSION" --iteration 1 --prefix / -C "$STAGE" \
  -p "$OUT/ophanim-av-${VERSION}-1.x86_64.rpm" .
fpm -s dir -t pacman -n ophanim-av -v "$VERSION" --iteration 1 --prefix / -C "$STAGE" \
  -p "$OUT/ophanim-av-${VERSION}-1-x86_64.pkg.tar.zst" .

echo "Linux artifacts:"
ls -lh "$OUT"
