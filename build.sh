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
cp Assets/HudMark.png "$APP/Contents/Resources/HudMark.png"
cp "Assets/HudMark@2x.png" "$APP/Contents/Resources/HudMark@2x.png"

# Sign with the local self-signed identity when it exists, so the designated
# requirement stays constant and macOS keeps the Accessibility grant across
# rebuilds. Ad-hoc signatures are content-derived, so every rebuild would
# otherwise invalidate the grant and the toggle would lie about being on.
IDENTITY="Murmur Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> signing as $IDENTITY"
else
  echo "==> signing (ad-hoc; run signing/create-identity.sh for a stable grant)"
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" --identifier com.yahyaelghobashy.murmur "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP"
