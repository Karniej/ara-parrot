#!/usr/bin/env bash
# Compiles the Metal kernel library the MLX formatting engine needs and places
# it next to every SwiftPM-built ara binary.
#
# Why this exists: SwiftPM cannot compile Metal shaders, so a plain
# `swift build` produces an ara binary with no `mlx.metallib`. The MLX
# runtime then fails at warm-up ("Failed to load the default metallib"),
# `ara doctor` warns, and formatting falls back to rule-based cleanup.
# xcodebuild *can* compile the shaders; this script builds the package once
# through xcodebuild to get mlx-swift's compiled kernel library, then copies it
# as `mlx.metallib` into the SwiftPM build directories — the first place MLX's
# loader looks is next to the running binary.
#
# The first run compiles the whole package through xcodebuild (~minutes); the
# derived data is kept, so re-runs only copy. Requires the Metal toolchain:
#   xcodebuild -downloadComponent MetalToolchain
#
# Usage:
#   scripts/build-metallib.sh [extra-destination-dir ...]
# Copies into .build's debug, release, and test-bundle directories when they
# exist, plus any directories passed as arguments (e.g. /usr/local/bin).
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${ARA_METALLIB_DD:-.build/metallib-derived-data}"
METALLIB="$DERIVED/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

if [ ! -f "$METALLIB" ]; then
    echo "→ compiling Metal shaders via xcodebuild (first run takes a few minutes)..."
    # -skipPackagePluginValidation: mlx-swift declares a build plugin
    # (CudaBuild) that xcodebuild refuses to run non-interactively without
    # per-user approval; it never runs for macOS builds, but validation alone
    # fails the build. SwiftPM itself runs the same package without asking.
    xcodebuild build -scheme ara -configuration Release \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation -quiet
fi

if [ ! -f "$METALLIB" ]; then
    echo "xcodebuild succeeded but produced no metallib at $METALLIB" >&2
    exit 1
fi

copied=0
for dir in \
    .build/arm64-apple-macosx/debug \
    .build/arm64-apple-macosx/release \
    .build/arm64-apple-macosx/debug/araPackageTests.xctest/Contents/MacOS \
    .build/arm64-apple-macosx/release/araPackageTests.xctest/Contents/MacOS \
    "$@"
do
    if [ -d "$dir" ]; then
        cp "$METALLIB" "$dir/mlx.metallib"
        echo "✓ $dir/mlx.metallib"
        copied=1
    fi
done

if [ "$copied" = 0 ]; then
    echo "no build directories found — run \`swift build\` first" >&2
    exit 1
fi
