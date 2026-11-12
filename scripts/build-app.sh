#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) GPCloud.app into ./dist.
# Needs only the Command Line Tools; Xcode is not required.
#   ARCHS="arm64"  ./scripts/build-app.sh   # single-arch, faster
#   GPCLOUD_SDK=/path/to/MacOSX.sdk ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
ARCHS=${ARCHS:-"arm64 x86_64"}

# The macOS 26.5 SDK in recent Command Line Tools fails to import WebKit with Swift 6.3.3
# ("could not build Objective-C module 'std'"). Prefer an SDK known to work; otherwise use the default.
if [[ -n "${GPCLOUD_SDK:-}" ]]; then
  export SDKROOT=$GPCLOUD_SDK
else
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk; do
    [[ -d $sdk ]] && export SDKROOT=$sdk && break
  done
fi
SDK_PATH=${SDKROOT:-$(xcrun --show-sdk-path)}
echo "▸ GP Cloud $VERSION · SDK: $SDK_PATH · archs: $ARCHS"

BINS=()
for arch in ${=ARCHS}; do
  echo "▸ Building $arch"
  swift build -c release --product GPCloud --triple "$arch-apple-macosx14.0"
  BINS+=("$(swift build -c release --product GPCloud --triple "$arch-apple-macosx14.0" --show-bin-path)/GPCloud")
done

APP=dist/GPCloud.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/GPCloud"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "▸ Rendering icon"
  mkdir -p build
  swiftc -sdk "$SDK_PATH" -O scripts/make-icon.swift -o build/make-icon
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GP Cloud</string>
  <key>CFBundleDisplayName</key><string>GP Cloud</string>
  <key>CFBundleIdentifier</key><string>io.github.azs06.gpcloud-mac</string>
  <key>CFBundleExecutable</key><string>GPCloud</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial client. Not affiliated with Grameenphone. MIT License.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (not notarized). See README for first-launch instructions.
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/GPCloud"))"
