#!/bin/zsh
# Regenerates docs/screenshots/macos/*.png from the app's offline demo mode (no account needed).
# Windows are captured by ID, so this doesn't need focus and works behind other windows.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=${ARCHS:-arm64} ./scripts/build-app.sh >/dev/null
BIN=dist/GPCloud.app/Contents/MacOS/GPCloud
SDK=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
[[ -d $SDK ]] || SDK=$(xcrun --show-sdk-path)
mkdir -p build ../docs/screenshots/macos
swiftc -sdk "$SDK" -O scripts/window-id.swift -o build/window-id

shoot() { # name view appearance
  GPCLOUD_DEMO=1 GPCLOUD_DEMO_VIEW=$2 GPCLOUD_DEMO_APPEARANCE=$3 "$BIN" >/dev/null 2>&1 &
  local pid=$!
  sleep 5
  local wid; wid=$(build/window-id $pid) || { kill $pid; echo "✗ no window found for $1" >&2; exit 1; }
  if ! screencapture -x -o -l "$wid" "../docs/screenshots/macos/$1.png" 2>/dev/null; then
    kill $pid
    echo "✗ couldn't capture $1. Is the display awake and unlocked? (Terminal also needs Screen Recording permission.)" >&2
    exit 1
  fi
  kill $pid; wait $pid 2>/dev/null || true
  echo "✓ docs/screenshots/macos/$1.png"
}

# Pick shots with: ./scripts/screenshots.sh menubar   (default: all)
want=${@:-"drive-grid drive-list menubar"}
[[ " $want " == *" drive-grid "* ]] && shoot drive-grid grid light
[[ " $want " == *" drive-list "* ]] && shoot drive-list list dark
[[ " $want " == *" menubar "* ]] && shoot menubar menubar light
true
