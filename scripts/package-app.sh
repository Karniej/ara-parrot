#!/usr/bin/env bash
# Assembles dist/Ara.app around the release binary.
#
# Why a bundle at all: a bare executable in /usr/local/bin cannot carry an
# Info.plist, and the Info.plist is what turns ara into a real macOS
# background app — `LSUIElement` (menu bar, no Dock icon, no app switcher
# entry), a stable bundle identifier for TCC to file the microphone and
# accessibility grants under, and the usage sentence macOS shows in the
# microphone prompt. A terminal process gets none of that; it inherits the
# terminal's permissions and its identity.
#
# ## The metallib goes in Contents/MacOS, not Contents/Resources
#
# MLX finds its kernel library relative to the *binary*, not the bundle: its
# loader calls dladdr on its own code (mlx/backend/common/utils.cpp,
# `current_binary_dir`) and, since Cmlx is statically linked into ara, that
# resolves to the directory holding the executable. It then tries
# `<dir>/mlx.metallib` and `<dir>/Resources/mlx.metallib`
# (mlx/backend/metal/device.cpp, `load_default_library`). Inside a bundle
# `<dir>` is Contents/MacOS, so Contents/MacOS/mlx.metallib is a hit and
# Contents/Resources/mlx.metallib — one level up from anything it looks at —
# is not. A miss is silent: warm-up fails, the chain falls through to
# rule-based cleanup, and dictation still types text, just unformatted.
#
# Usage:
#   swift build -c release
#   scripts/build-metallib.sh
#   scripts/package-app.sh [output-dir]      # default: dist
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${ARA_RELEASE_DIR:-.build/release}"
BINARY="$BUILD/ara"
METALLIB="$BUILD/mlx.metallib"
ICON="packaging/Ara.icns"
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/Ara.app"

if [ ! -f VERSION ]; then
    echo "no VERSION file at $(pwd)/VERSION — it is the one place the release number lives" >&2
    exit 1
fi
# Single source of truth for the number: this file feeds Info.plist, the DMG's
# filename, and `ara --version` (which reads it back out of Info.plist at
# runtime). A git tag would be the other candidate, but tags are absent from
# source tarballs and from a fresh shallow clone, and a packaging script that
# produces "Ara-.dmg" on a CI checkout is worse than one that reads a file
# that is always there.
VERSION=$(tr -d '[:space:]' < VERSION)
if [ -z "$VERSION" ]; then
    echo "VERSION is empty" >&2
    exit 1
fi

if [ ! -x "$BINARY" ]; then
    echo "no release binary at $BINARY — run \`swift build -c release\`" >&2
    exit 1
fi

if [ ! -f "$METALLIB" ]; then
    echo "no Metal kernel library at $METALLIB — run \`scripts/build-metallib.sh\`" >&2
    echo "without it the packaged app loads no local formatting model and silently" >&2
    echo "falls back to rule-based cleanup." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/ara"
chmod +x "$APP/Contents/MacOS/ara"
# Beside the executable. See the header — Contents/Resources is not a place
# MLX's loader looks.
cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"

ICON_KEY=""
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/Ara.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>
    <string>Ara</string>"
else
    echo "note: no $ICON — the app will use the generic macOS icon" \
        "(run \`scripts/build-icon.sh\` to make one)" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ara</string>
    <key>CFBundleIdentifier</key>
    <string>com.silpho.ara</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Ara</string>
    <key>CFBundleDisplayName</key>
    <string>Ara</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
$ICON_KEY
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Ara turns what you say into text at your cursor. Recording starts when you hold the hotkey and stops when you release it; the audio is transcribed on this Mac and never leaves it.</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed. https://github.com/Karniej/ara-parrot</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Verify what was built rather than trusting the copies above: an Info.plist
# that will not parse produces an app Finder refuses to launch, with no error
# anywhere the user can see.
if ! plutil -lint "$APP/Contents/Info.plist" >/dev/null; then
    echo "the generated Info.plist is not valid — refusing to ship $APP" >&2
    exit 1
fi
if [ ! -f "$APP/Contents/MacOS/mlx.metallib" ]; then
    echo "mlx.metallib did not land beside the executable" >&2
    exit 1
fi

# Ad-hoc sign the bundle. Not optional, and not the same thing as shipping
# unsigned: the linker already ad-hoc signs the executable, so a bundle that
# is never signed as a bundle has an executable signature and no
# `_CodeSignature/CodeResources` — an *invalid* state, not an absent one.
# `codesign --verify` fails it and Gatekeeper reports it as damaged, which is
# a worse first run than the honest unsigned prompt. Signing with `-` needs no
# certificate; a maintainer with a Developer ID sets `ARA_SIGN_IDENTITY` and
# gets the timestamp and entitlements with it.
#
# Signed inner-out rather than with `--deep`, which Apple documents as a
# verification convenience and discourages for signing. The metallib has to be
# signed first: it lives in Contents/MacOS (where MLX's loader looks), and
# codesign treats everything there as a nested code object — sealing the
# bundle around an unsigned one fails with "code object is not signed at all".
# `ARA_SIGN_IDENTITY` picks the certificate. Unset means `-`, the ad-hoc
# signature, which is what a contributor with no Apple account gets and what
# the honest "unsigned, right-click to open" install has always been.
#
# A real Developer ID changes three things, and all three are required
# together: the timestamp (notarization refuses a signature without one), the
# entitlements (the hardened runtime is already on, so the microphone has to be
# asked for by name), and the identity itself. Getting one of the three wrong
# produces a bundle that signs, verifies, and is then rejected minutes later by
# a service — which is why they are set in one place rather than three.
IDENTITY="${ARA_SIGN_IDENTITY:--}"
SIGN_EXTRA=()
if [ "$IDENTITY" != "-" ]; then
    SIGN_EXTRA=(--timestamp --entitlements packaging/Ara.entitlements)
    echo "→ signing as $IDENTITY"
fi

if ! codesign --force "${SIGN_EXTRA[@]}" --sign "$IDENTITY" \
        "$APP/Contents/MacOS/mlx.metallib" 2>/dev/null; then
    echo "could not sign the Metal kernel library" >&2
    exit 1
fi
if ! codesign --force --options runtime "${SIGN_EXTRA[@]}" --sign "$IDENTITY" "$APP"; then
    echo "signing failed — the bundle would be reported as damaged" >&2
    exit 1
fi
# Verified, not assumed: this is the check Gatekeeper's own evaluation starts
# from, and the defect it catches is invisible until a user double-clicks.
if ! codesign --verify "$APP" 2>/dev/null; then
    echo "the signed bundle does not verify — refusing to ship $APP" >&2
    exit 1
fi

echo "✓ $APP ($VERSION, $(du -sh "$APP" | cut -f1))"
echo "  binary:   Contents/MacOS/ara"
echo "  metallib: Contents/MacOS/mlx.metallib (beside the binary — MLX looks there)"
if [ -n "$ICON_KEY" ]; then
    echo "  icon:     Contents/Resources/Ara.icns"
fi
echo
echo "next: scripts/package-dmg.sh"
