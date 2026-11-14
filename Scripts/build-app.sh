#!/bin/sh
# Builds dist/"Analytics Desktop.app" — a native arm64 (Apple silicon) release build, ad-hoc signed for local use.
# Usage: Scripts/build-app.sh [--open]
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/Analytics Desktop.app"

echo "▸ Compiling (release, arm64)…"
swift build -c release --arch arm64 --product MicrosoftPowerBI
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MicrosoftPowerBI"

echo "▸ Assembling $APP"
rm -rf "$APP"
WORK="$(mktemp -d)"
STAGE="$WORK/Analytics Desktop.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/MicrosoftPowerBI"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"

ICONSET="$(mktemp -d)/MicrosoftPowerBI.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/MicrosoftPowerBI.icns"

# Stage under a neutral path, clear extended attributes there, then sign the final location —
# signing after the copy keeps the sealed resources intact (file-provider attributes otherwise
# break verification).
mkdir -p "$(dirname "$APP")"
cp -R "$STAGE" "$APP"
rm -rf "$WORK"

echo "▸ Signing (ad hoc)"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP"

echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/MicrosoftPowerBI"))"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
