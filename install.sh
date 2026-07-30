#!/usr/bin/env bash
# ara installer.
#   curl -fsSL https://karniej.github.io/ara-parrot/install.sh | sh
#
# Installs the latest Ara release from GitHub Releases.
#
# Two shapes of asset can be published, and this handles both:
#
#   Ara-<version>.dmg          the app bundle (what `scripts/package-dmg.sh`
#                              builds and what v0.1.0 ships). Preferred: the
#                              microphone and accessibility grants stick to
#                              the bundle rather than to whatever launched it.
#                              Mounted, copied to /Applications, and the CLI
#                              inside it symlinked onto your PATH.
#   ara-macos-arm64.tar.gz     the bare CLI (what .github/workflows/release.yml
#                              builds). Fallback: no Info.plist, so the process
#                              runs under the identity of its launcher.
#
# Either way the quarantine xattr is stripped, because builds are unsigned and
# Gatekeeper otherwise refuses them outright.
#
# Apple Silicon only — WhisperKit uses the Apple Neural Engine via CoreML,
# which only ships on M-series chips.

set -euo pipefail

REPO="Karniej/ara-parrot"
BIN_NAME="ara"
INSTALL_DIR="/usr/local/bin"
APP_DIR="/Applications"
TARBALL="ara-macos-arm64.tar.gz"

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }

# 1. sanity
if [ "$(uname -s)" != "Darwin" ]; then
    red "ara is macOS-only (detected $(uname -s))"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    red "ara requires Apple Silicon (detected $ARCH)"
    red "the on-device inference engine uses the Apple Neural Engine, which Intel Macs don't have."
    exit 1
fi

for cmd in curl tar shasum hdiutil; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

TMP=$(mktemp -d)
MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# 2. resolve the latest release, and what it actually published
dim "→ resolving latest release..."
if ! curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    -o "$TMP/release.json" 2>/dev/null; then
    red "no published release for ${REPO} yet — nothing to download."
    red ""
    red "build from source instead (macOS 14+, Apple Silicon, Xcode for the Metal step):"
    red ""
    red "  git clone https://github.com/${REPO}.git && cd ara-parrot"
    red "  swift build -c release"
    red "  scripts/build-metallib.sh"
    red "  ./.build/release/${BIN_NAME} models download-formatter"
    red "  ./.build/release/${BIN_NAME} setup"
    red "  ./.build/release/${BIN_NAME}"
    red ""
    red "see https://github.com/${REPO}#install"
    exit 1
fi

TAG=$(grep -E '"tag_name"' "$TMP/release.json" | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

# Read the asset URLs out of the release rather than guessing filenames: the
# DMG carries the version in its name, and which of the two shapes a given
# tag published is not knowable ahead of time.
ASSETS=$(grep -Eo '"browser_download_url": *"[^"]+"' "$TMP/release.json" \
    | sed -E 's/.*"(https[^"]+)"/\1/')

DMG_URL=$(printf '%s\n' "$ASSETS" | grep -E '\.dmg$' | head -1 || true)
TAR_URL=$(printf '%s\n' "$ASSETS" | grep -E "/${TARBALL}\$" | head -1 || true)

if [ -z "$DMG_URL" ] && [ -z "$TAR_URL" ]; then
    red "release ${TAG} publishes neither a .dmg nor ${TARBALL}"
    red "see https://github.com/${REPO}/releases/tag/${TAG}"
    exit 1
fi

# Unsigned builds make the checksum the only integrity check there is, so a
# mismatch is fatal. A *missing* sums file is not: not every tag publishes
# one (v0.1.0 puts the DMG's sha256 in the release notes instead), so print
# what we got and let the user compare.
verify() {
    file="$1"; url="$2"; name=$(basename "$file")
    dim "→ verifying ${name}..."
    if curl -fsSL "${url}.sha256" -o "$TMP/sums" 2>/dev/null; then
        expected=$(cut -d' ' -f1 < "$TMP/sums")
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
        if [ "$expected" != "$actual" ]; then
            red "checksum mismatch for ${name}"
            red "  expected ${expected}"
            red "  got      ${actual}"
            red "refusing to install."
            exit 1
        fi
        dim "  ok"
    else
        dim "  no ${name}.sha256 published; compare this against the release notes:"
        dim "  $(shasum -a 256 "$file" | cut -d' ' -f1)"
    fi
}

# `sudo` only where the destination is not already writable — /Applications is
# group-writable by admin on a stock Mac, /usr/local/bin often is not.
as_owner() {
    dest="$1"; shift
    if [ -w "$dest" ]; then "$@"; else sudo "$@"; fi
}

if [ -n "$DMG_URL" ]; then
    # 3a. app bundle
    DMG="$TMP/$(basename "$DMG_URL")"
    dim "→ downloading $(basename "$DMG_URL")..."
    curl -fsSL "$DMG_URL" -o "$DMG"
    verify "$DMG" "$DMG_URL"

    dim "→ mounting..."
    MOUNT=$(mktemp -d)
    hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet

    if [ ! -x "$MOUNT/Ara.app/Contents/MacOS/${BIN_NAME}" ]; then
        red "the image has no Ara.app/Contents/MacOS/${BIN_NAME}"
        exit 1
    fi

    dim "→ installing ${APP_DIR}/Ara.app..."
    # Replace rather than merge: copying over a bundle leaves the previous
    # version's files behind inside it.
    as_owner "$APP_DIR" rm -rf "$APP_DIR/Ara.app"
    as_owner "$APP_DIR" cp -R "$MOUNT/Ara.app" "$APP_DIR/Ara.app"

    hdiutil detach "$MOUNT" -quiet
    MOUNT=""

    # Unsigned + quarantined is the combination Gatekeeper refuses outright.
    as_owner "$APP_DIR" xattr -dr com.apple.quarantine "$APP_DIR/Ara.app" 2>/dev/null || true

    # The bundle's CLI is the same binary; put it on PATH so `ara …` works,
    # and so `ara install --launch-at-login` points the agent at the bundle.
    if [ ! -d "$INSTALL_DIR" ]; then
        dim "→ creating ${INSTALL_DIR}..."
        as_owner "$(dirname "$INSTALL_DIR")" mkdir -p "$INSTALL_DIR"
    fi
    dim "→ linking ${INSTALL_DIR}/${BIN_NAME}..."
    as_owner "$INSTALL_DIR" ln -sf "$APP_DIR/Ara.app/Contents/MacOS/${BIN_NAME}" \
        "${INSTALL_DIR}/${BIN_NAME}"

    green "✓ Ara ${TAG} installed at ${APP_DIR}/Ara.app"
    dim "  ${INSTALL_DIR}/${BIN_NAME} → ${APP_DIR}/Ara.app/Contents/MacOS/${BIN_NAME}"
else
    # 3b. bare CLI
    dim "→ downloading ${TARBALL}..."
    curl -fsSL "$TAR_URL" -o "$TMP/${TARBALL}"
    verify "$TMP/${TARBALL}" "$TAR_URL"

    dim "→ extracting..."
    tar -xzf "$TMP/${TARBALL}" -C "$TMP"

    if [ ! -f "$TMP/${BIN_NAME}" ]; then
        red "archive did not contain ${BIN_NAME}"
        exit 1
    fi

    chmod +x "$TMP/${BIN_NAME}"
    xattr -d com.apple.quarantine "$TMP/${BIN_NAME}" 2>/dev/null || true

    if [ ! -d "$INSTALL_DIR" ]; then
        dim "→ creating ${INSTALL_DIR}..."
        as_owner "$(dirname "$INSTALL_DIR")" mkdir -p "$INSTALL_DIR"
    fi
    dim "→ installing to ${INSTALL_DIR}/${BIN_NAME}..."
    as_owner "$INSTALL_DIR" mv "$TMP/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
    as_owner "$INSTALL_DIR" chmod +x "${INSTALL_DIR}/${BIN_NAME}"

    green "✓ ara ${TAG} installed at ${INSTALL_DIR}/${BIN_NAME}"
    dim "  CLI only — no bundle, so permissions attach to whatever launches it."
fi

echo
echo "next:"
echo "  ara setup                        # grant mic + accessibility"
echo "  ara models download-formatter    # local cleanup model, ~900 MB, once"
echo "  ara install --launch-at-login    # (optional) start at login"
echo "  ara                              # run the daemon"
