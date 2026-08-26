#!/usr/bin/env bash
# Regenerates packaging/Ara.icns from the mark in Sources/AraCore/UI/Brand.swift.
#
# The icon used to be cropped out of the README banner with sips — the
# line-art macaw on a branch, padded to a square. That artwork is still the
# banner, but it is no longer the product's mark: the menu bar, the setup
# window and the Dock tile all draw `AraMarkImage`, which is the iOS app's
# icon ported. An .icns cut from the banner made the bundle the one place ara
# looked like a different application.
#
# So the master comes from the same code every other surface draws. There is
# no image file to keep in step, and no second copy of the bird to update when
# the first one changes.
#
# The .icns is committed, so this only needs re-running when the mark changes.
# Uses iconutil and sips, both part of macOS, and the test target's renderer.
#
# Usage:
#   scripts/build-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT="packaging/Ara.icns"

for tool in sips iconutil swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing $tool" >&2
        exit 1
    fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Ara.iconset"
mkdir -p "$ICONSET"

echo "→ rendering the mark at 1024px..."
# One master, rendered once, so every size below is a downsample of the same
# image rather than an independent draw. `renderAppIcon` writes it when
# ARA_ICON_MASTER is set; without that variable the same test only measures.
ARA_ICON_MASTER="$WORK/master.png" \
    swift test --filter renderAppIcon 2>&1 | grep -E "icon-master|error:" || true

if [ ! -f "$WORK/master.png" ]; then
    echo "the renderer wrote nothing — run 'swift test --filter renderAppIcon' to see why" >&2
    exit 1
fi

echo "→ rendering iconset sizes..."
# name:pixels — the @2x entries are the same pixel counts under the names
# iconutil expects, which is what makes Retina rendering sharp.
for entry in \
    icon_16x16:16 icon_16x16@2x:32 \
    icon_32x32:32 icon_32x32@2x:64 \
    icon_128x128:128 icon_128x128@2x:256 \
    icon_256x256:256 icon_256x256@2x:512 \
    icon_512x512:512 icon_512x512@2x:1024
do
    name=${entry%:*}
    px=${entry#*:}
    sips -z "$px" "$px" "$WORK/master.png" --out "$ICONSET/$name.png" >/dev/null
done

echo "→ packing $OUTPUT..."
iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "✓ $OUTPUT"
