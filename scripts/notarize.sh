#!/usr/bin/env bash
# Notarizes a signed Ara.app or Ara DMG and staples the ticket to it.
#
# ## Why this matters more than the Gatekeeper prompt
#
# The obvious win is that a notarized build opens with a double-click instead
# of right-click → Open. The bigger one is invisible: macOS files TCC grants
# and the Core ML Neural Engine cache against the code signature. An ad-hoc
# signature is unique to one build, so every new copy of ara arrives as a
# stranger — the microphone and accessibility grants stop applying, and the
# two-and-a-half-minute model compile runs again. A Developer ID is stable
# across builds, so both survive an update.
#
# ## What it needs
#
#   - A signed bundle. Sign with `ARA_SIGN_IDENTITY="Developer ID Application:
#     ..." scripts/package-app.sh`; an ad-hoc signature is rejected.
#   - Credentials, in one of two forms. Locally, a notarytool profile, created
#     once:
#       xcrun notarytool store-credentials ara \
#         --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#         --key-id XXXX --issuer <issuer-uuid>
#     `ARA_NOTARY_PROFILE` overrides the name; it defaults to `ara`.
#
#     In CI there is no keychain to hold a profile, so `ARA_NOTARY_KEY` (a path
#     to the .p8), `ARA_NOTARY_KEY_ID` and `ARA_NOTARY_ISSUER` are used instead
#     when all three are set. One script either way: a release built by hand and
#     a release built by the workflow go through the same code, which is the
#     only way the local path stays honest about what CI does.
#
# Usage:
#   scripts/notarize.sh [path]        # defaults to dist/Ara.app
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-dist/Ara.app}"
PROFILE="${ARA_NOTARY_PROFILE:-ara}"

if [ ! -e "$TARGET" ]; then
    echo "nothing at $TARGET — run scripts/package-app.sh first" >&2
    exit 1
fi

# An ad-hoc signature is refused here rather than by Apple ten minutes later.
# The failure at the far end is a log URL and a JSON document; the failure here
# is one line naming the variable to set.
if codesign -dv "$TARGET" 2>&1 | grep -q "Signature=adhoc"; then
    echo "$TARGET is ad-hoc signed; notarization needs a Developer ID." >&2
    echo "  ARA_SIGN_IDENTITY=\"Developer ID Application: ...\" scripts/package-app.sh" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

case "$TARGET" in
    *.app)
        # An .app cannot be submitted directly — the service takes an archive,
        # a disk image or an installer package. `ditto` rather than `zip`,
        # because only ditto preserves the symlinks and extended attributes a
        # bundle's signature is sealed over.
        SUBMISSION="$WORK/$(basename "${TARGET%.app}").zip"
        echo "→ archiving $TARGET..."
        ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
        ;;
    *)
        SUBMISSION="$TARGET"
        ;;
esac

if [ -n "${ARA_NOTARY_KEY:-}" ] && [ -n "${ARA_NOTARY_KEY_ID:-}" ] \
        && [ -n "${ARA_NOTARY_ISSUER:-}" ]; then
    CREDENTIALS=(--key "$ARA_NOTARY_KEY" --key-id "$ARA_NOTARY_KEY_ID"
                 --issuer "$ARA_NOTARY_ISSUER")
    HOW="--key ... --key-id $ARA_NOTARY_KEY_ID --issuer ..."
else
    CREDENTIALS=(--keychain-profile "$PROFILE")
    HOW="--keychain-profile $PROFILE"
fi

echo "→ submitting to Apple (this usually takes a few minutes)..."
if ! xcrun notarytool submit "$SUBMISSION" "${CREDENTIALS[@]}" --wait; then
    echo >&2
    echo "notarization failed. The log says why:" >&2
    echo "  xcrun notarytool log <submission-id> $HOW" >&2
    exit 1
fi

# Stapling is what makes the ticket travel with the file. Without it every
# first launch needs the network to ask Apple whether this build is known —
# which is exactly the moment a new user has no reason to wait.
echo "→ stapling..."
xcrun stapler staple "$TARGET"

echo "→ verifying as Gatekeeper sees it..."
spctl --assess --type execute --verbose=2 "$TARGET" 2>&1 | sed 's/^/  /'
echo "✓ $TARGET is notarized and stapled"
