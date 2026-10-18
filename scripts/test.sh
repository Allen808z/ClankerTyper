#!/bin/bash
# Runs the unit tests. This Mac has Command Line Tools only (no Xcode), where the Swift Testing
# framework lives outside the default search path, so the paths are passed explicitly.
set -euo pipefail
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$INTEROP"
