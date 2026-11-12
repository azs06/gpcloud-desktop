#!/bin/zsh
# Builds the app and zips it for a GitHub release: dist/GPCloud-<version>-macOS.zip (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
VERSION=$(cat VERSION)
ZIP="dist/GPCloud-$VERSION-macOS.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent dist/GPCloud.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "✓ $ZIP"
cat "$ZIP.sha256"
