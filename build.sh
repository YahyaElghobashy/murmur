#!/usr/bin/env bash
# Build Murmur.app from source. No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Murmur.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling (swift $(swift --version 2>&1 | head -1 | sed 's/.*version //;s/ .*//'))"
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/Murmur" \
  Sources/Diag.swift Sources/Core.swift Sources/Audio.swift Sources/HUD.swift Sources/App.swift

cp Info.plist "$APP/Contents/Info.plist"
cp Assets/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
cp Assets/MenuGlyph.png "$APP/Contents/Resources/MenuGlyph.png"
cp "Assets/MenuGlyph@2x.png" "$APP/Contents/Resources/MenuGlyph@2x.png"

echo "==> signing (ad-hoc)"
# Ad-hoc signature. Keeps the bundle launchable and keeps TCC grants stable
# as long as the bundle id and path do not change.
codesign --force --deep --sign - --identifier com.yahyaelghobashy.murmur "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP"
