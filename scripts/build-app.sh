#!/bin/bash
# Builds ClankerTyper with SwiftPM and wraps it in a signed .app bundle under build/.
# Ad-hoc signing only: no Developer ID, no notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/build/ClankerTyper.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClankerTyper" "$APP/Contents/MacOS/ClankerTyper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICON_PNG="$ROOT/build/AppIcon-1024.png"
mkdir -p "$ROOT/build"
if [ ! -f "$ICON_PNG" ]; then
  swift "$ROOT/scripts/make-icon.swift" "$ICON_PNG" 1024 >/dev/null
fi
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing pins the code requirement to the cdhash by default, so every rebuild looks like
# a new app to macOS and privacy grants (Microphone, Screen Recording, ...) are dropped. Pinning the
# requirement to the bundle identifier keeps grants across rebuilds. Only ad-hoc signing is used here.
codesign --force --deep --sign - \
  --identifier dev.local.clanker \
  -r='designated => identifier "dev.local.clanker"' \
  "$APP" >/dev/null
echo "Built $APP"
