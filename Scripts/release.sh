#!/bin/sh
# Builds a signed release of Analytics Desktop into dist/:
#   AnalyticsDesktop-<version>.zip       the app, zipped with ditto (what the in-app updater downloads)
#   AnalyticsDesktop-<version>.zip.sig   Ed25519 signature of the zip's bytes (base64)
#   latest.json                          version, notes URL, asset URLs, sizes and SHA-256 checksums
#   release-notes.md                     the version's section of CHANGELOG.md (the GitHub release body)
#
#   UPDATE_SIGNING_KEY=<base64 private key> Scripts/release.sh <version> [build-number]
#
# <version> is the tag without its "v" (0.9.0, 1.0.0-beta.1). The build number defaults to the commit count.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REPO="Edwardrem/analytics-desktop"

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then echo "Usage: Scripts/release.sh <version> [build-number]" >&2; exit 2; fi
BUILD="${2:-$(git rev-list --count HEAD)}"

if [ -z "${UPDATE_SIGNING_KEY:-}" ]; then
    echo "UPDATE_SIGNING_KEY is not set: releases must be signed or installed copies will refuse them." >&2
    echo "See Scripts/make-update-key.sh." >&2
    exit 1
fi
if [ ! -f "$ROOT/Resources/UpdatePublicKey.txt" ]; then
    echo "Resources/UpdatePublicKey.txt is missing: run Scripts/make-update-key.sh and commit the key first." >&2
    exit 1
fi

# The notes come from CHANGELOG.md's "## [<version>]" section; a release without notes is a mistake.
NOTES="$ROOT/dist/release-notes.md"
mkdir -p "$ROOT/dist"
awk -v v="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## [" v "]") == 1 || index($0, "## " v) == 1) { found = 1; next } }
    found { print }
' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d' > "$NOTES"
if [ ! -s "$NOTES" ]; then
    echo "CHANGELOG.md has no section for $VERSION (expected a heading like '## [$VERSION] - YYYY-MM-DD')." >&2
    exit 1
fi

"$ROOT/Scripts/build-app.sh" --version "$VERSION" --build "$BUILD"

cd "$ROOT/dist"
ZIP="AnalyticsDesktop-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig" latest.json
echo "▸ Zipping $ZIP"
ditto -c -k --keepParent "Analytics Desktop.app" "$ZIP"

echo "▸ Signing"
swift "$ROOT/Scripts/sign-update.swift" sign "$ZIP" > "$ZIP.sig"
swift "$ROOT/Scripts/sign-update.swift" verify "$ROOT/Resources/UpdatePublicKey.txt" "$ZIP" "$ZIP.sig"

size() { stat -f %z "$1"; }
sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
DOWNLOAD="https://github.com/$REPO/releases/download/v$VERSION"
cat > latest.json <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "notesURL": "https://github.com/$REPO/releases/tag/v$VERSION",
  "archive": {
    "name": "$ZIP",
    "url": "$DOWNLOAD/$ZIP",
    "size": $(size "$ZIP"),
    "sha256": "$(sha "$ZIP")"
  },
  "signature": {
    "name": "$ZIP.sig",
    "url": "$DOWNLOAD/$ZIP.sig",
    "size": $(size "$ZIP.sig"),
    "sha256": "$(sha "$ZIP.sig")"
  }
}
JSON

echo "✓ dist/$ZIP, dist/$ZIP.sig, dist/latest.json and dist/release-notes.md are ready for v$VERSION (build $BUILD)."
