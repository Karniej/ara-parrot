#!/usr/bin/env bash
# Wraps dist/Ara.app in a compressed, read-only Ara-<version>.dmg with an
# /Applications symlink beside it, so the whole install is one drag.
#
# The image is unsigned and unnotarized — see the README's "Unsigned builds"
# section for what that means on the downloader's machine and for the exact
# commands a maintainer with a Developer ID would run to fix it.
#
# Usage:
#   scripts/package-app.sh
#   scripts/package-dmg.sh [output-dir]      # default: dist
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
APP="$OUT_DIR/Ara.app"

if [ ! -f VERSION ]; then
    echo "no VERSION file at $(pwd)/VERSION" >&2
    exit 1
fi
VERSION=$(tr -d '[:space:]' < VERSION)
if [ -z "$VERSION" ]; then
    echo "VERSION is empty" >&2
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "no app bundle at $APP — run \`scripts/package-app.sh\`" >&2
    exit 1
fi
if [ ! -x "$APP/Contents/MacOS/ara" ]; then
    echo "$APP has no executable at Contents/MacOS/ara — rebuild it with \`scripts/package-app.sh\`" >&2
    exit 1
fi

DMG="$OUT_DIR/Ara-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Copy rather than point hdiutil at dist/: the staging directory must contain
# the app and the /Applications alias and nothing else, and dist/ also holds
# the previous DMGs.
cp -R "$APP" "$STAGE/Ara.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "→ building $DMG..."
# UDZO: zlib-compressed, read-only. The alternative (UDRW) would ship a
# writable image, which mounts dirty and cannot be checksummed by a
# downloader.
hdiutil create \
    -volname "Ara $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    -ov \
    "$DMG"

if [ ! -f "$DMG" ]; then
    echo "hdiutil reported success but produced no image at $DMG" >&2
    exit 1
fi

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
echo "  sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "unsigned: a downloader must right-click → Open on first launch, or run"
echo "  xattr -d com.apple.quarantine /Applications/Ara.app"
