#!/bin/bash
# Builds Clanker and installs it as /Applications/Clanker.app, replacing an earlier install.
# Permissions carry over between installs because the signature is pinned to the bundle id.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Clanker.app"

"$ROOT/scripts/build-app.sh"

# Quit any running copy (from build/ or Applications) so the files can be replaced.
pkill -f "Clanker.app/Contents/MacOS/Clanker" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
ditto "$ROOT/build/Clanker.app" "$DEST"
echo "Installed $DEST"

if [ "${1:-}" != "--no-open" ]; then
  open "$DEST"
fi
