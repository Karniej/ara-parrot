#!/bin/bash
# Dumps the prompts TranscriptPrompt actually produces, byte-exact, into
# scripts/cleanup-eval/prompts/ (or a directory given as $1).
#
# It compiles fresh copies of the real sources with a tiny driver
# (dump_main.swift) — no package build needed, a few seconds. Run this before
# every eval so the measurement can never drift from the shipped prompt.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/prompts}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# AraEngine, not AraCore. These four moved when the portable engine was split
# out — the harness kept the old paths and failed with four `cp: no such file`
# lines, which is a loud failure but not an obvious one if you are reading the
# tail of the output for a result.
cp "$ROOT/Sources/AraEngine/Formatting/TranscriptPrompt.swift" \
   "$ROOT/Sources/AraEngine/Formatting/CleanupIntensity.swift" \
   "$ROOT/Sources/AraEngine/Modes/Mode.swift" \
   "$ROOT/Sources/AraEngine/Modes/ModeRegistry.swift" \
   "$HERE/dump_main.swift" "$TMP/"
mv "$TMP/dump_main.swift" "$TMP/main.swift"

swiftc -o "$TMP/dump" "$TMP"/*.swift
mkdir -p "$OUT"
"$TMP/dump" "$OUT"
ls "$OUT"/prompt_*.txt
