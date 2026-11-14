#!/bin/sh
# Builds dist/"Analytics Desktop.app" — a native arm64 (Apple silicon) release build, ad-hoc signed for local use.
# Usage: Scripts/build-app.sh [--open] [--version X.Y.Z] [--build N]
#   --version sets CFBundleShortVersionString (Scripts/release.sh passes the tag's version);
#   --build sets CFBundleVersion. Without them the values in Resources/Info.plist are used.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/Analytics Desktop.app"
OPEN=0
VERSION=""
BUILD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --open) OPEN=1 ;;
        --version) VERSION="${2:?--version needs a value}"; shift ;;
        --build) BUILD="${2:?--build needs a value}"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
if [ -n "$VERSION" ] && ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    echo "Version must look like 1.2.3 or 1.2.3-beta.1, not '$VERSION'." >&2; exit 2
fi
if [ -n "$BUILD" ] && ! printf '%s' "$BUILD" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    echo "Build number must be numeric, not '$BUILD'." >&2; exit 2
fi

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
[ -n "$VERSION" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGE/Contents/Info.plist"
[ -n "$BUILD" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$STAGE/Contents/Info.plist"
# The Ed25519 key in-app updates are checked against (Scripts/make-update-key.sh writes it). Without it the
# app still runs, but refuses to install updates.
if [ -f "$ROOT/Resources/UpdatePublicKey.txt" ]; then
    cp "$ROOT/Resources/UpdatePublicKey.txt" "$STAGE/Contents/Resources/UpdatePublicKey.txt"
else
    echo "▸ Note: Resources/UpdatePublicKey.txt is missing, so this build can't install updates."
fi

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
[ "$OPEN" = 1 ] && open "$APP"
exit 0
