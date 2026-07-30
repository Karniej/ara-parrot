#!/usr/bin/env bash
# Not the installer. A signpost to it.
#
# The installer people actually run is served from the landing page:
#
#     curl -fsSL https://karniej.github.io/ara-parrot/install.sh | sh
#
# and it lives on the gh-pages branch, which is where the README points and
# where it gets edited. This file used to be a second, independent copy of it
# on master, and it drifted: it only knew about the tarball asset, skipped
# checksum verification entirely, and installed to /usr/local/bin with sudo,
# long after the canonical one had learned to prefer the DMG, verify the
# published .sha256, and install per-user without escalating.
#
# Keeping a synchronised copy here would only re-create that drift the next
# time the landing page is touched — which is exactly how the divergence
# happened. So this is a pointer, and it fails loudly rather than installing
# something worse than what the documented URL gives you: a stale installer
# that silently hands you a bundle-less CLI is the failure mode the release
# workflow was just fixed to prevent, and it would be perverse to keep one
# here.
#
# Building from source instead? See the README's "Build from source", or:
#
#     swift build -c release
#     scripts/build-metallib.sh      # the Metal kernels SwiftPM can't compile
#     scripts/package-app.sh         # dist/Ara.app
#     scripts/package-dmg.sh         # dist/Ara-<version>.dmg

set -euo pipefail

cat >&2 <<'MSG'
scripts/install.sh is not the installer — it is a pointer, so that master and
the landing page cannot disagree about how Ara is installed.

Install Ara with:

    curl -fsSL https://karniej.github.io/ara-parrot/install.sh | sh

That script resolves the newest release, prefers the Ara-<version>.dmg app
bundle over the bare CLI tarball, verifies the published .sha256, strips the
quarantine xattr, and installs per-user without sudo.

To build from source instead, see https://github.com/Karniej/ara-parrot#install
MSG

exit 1
