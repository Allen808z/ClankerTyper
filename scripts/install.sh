#!/bin/bash
# Builds ClankerTyper and installs it as /Applications/ClankerTyper.app, replacing an earlier install.
# Permissions carry over between installs because the signature is pinned to the bundle id.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/ClankerTyper.app"

"$ROOT/scripts/build-app.sh"

# Quit any running copy (from build/ or Applications) so the files can be replaced.
pkill -f "ClankerTyper.app/Contents/MacOS/ClankerTyper" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
# The app was called Clanker before. Remove that install only if it is this app (same bundle id).
OLD="/Applications/Clanker.app"
if [ -d "$OLD" ] && [ "$(defaults read "$OLD/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "dev.local.clanker" ]; then
  rm -rf "$OLD"
  echo "Removed the old $OLD"
fi
ditto "$ROOT/build/ClankerTyper.app" "$DEST"
echo "Installed $DEST"

if [ "${1:-}" != "--no-open" ]; then
  open "$DEST"
fi
