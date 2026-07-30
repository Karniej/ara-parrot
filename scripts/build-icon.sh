#!/usr/bin/env bash
# Regenerates packaging/Ara.icns from the README banner.
#
# The banner (docs/assets/ara.png, 1774x887) is a wide black plate: macaw on
# the left, waveform and wordmark on the right. A square crop of the middle
# would be the letter "A"; a square crop of the left third would cut the tail
# off. So this crops to the bird's own bounding box — a 425x630 window whose
# numbers are measured from the artwork, not guessed — and then pads that
# portrait rectangle out to a square with the same black the banner already
# uses. The result is the bird, centred, with the wordmark gone.
#
# The .icns is committed, so this only needs re-running when the banner
# changes. Uses sips and iconutil, both part of macOS.
#
# Usage:
#   scripts/build-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="docs/assets/ara.png"
OUTPUT="packaging/Ara.icns"

# The bird's bounding box in the banner: x 300..725, y 145..775. Includes the
# branch (which reaches further left than the body) and the full tail (which
# reaches nearly to the bottom edge).
CROP_X=300
CROP_Y=145
CROP_W=425
CROP_H=630
# Padded square. 740 leaves ~7% breathing room above and below the tallest
# part of the artwork, which is what keeps it from looking cropped at 16px.
SQUARE=740

if [ ! -f "$SOURCE" ]; then
    echo "no banner at $SOURCE — this script draws the icon from it" >&2
    exit 1
fi

for tool in sips iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing $tool (ships with macOS)" >&2
        exit 1
    fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Ara.iconset"
mkdir -p "$ICONSET"

echo "→ cropping the macaw out of $SOURCE..."
sips -c "$CROP_H" "$CROP_W" --cropOffset "$CROP_Y" "$CROP_X" \
    "$SOURCE" --out "$WORK/bird.png" >/dev/null
# Black, because the artwork is line-art on black and any other pad colour
# would show as a frame around it.
sips -p "$SQUARE" "$SQUARE" --padColor 000000 \
    "$WORK/bird.png" --out "$WORK/square.png" >/dev/null
# One master, upscaled once, so every icon size is a downsample of the same
# image rather than an independent resample of a 630px original.
sips -z 1024 1024 "$WORK/square.png" --out "$WORK/master.png" >/dev/null

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

mkdir -p "$(dirname "$OUTPUT")"
iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "✓ $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
