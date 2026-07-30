# Release CI: publishing the app bundle on a tag

Branch `feature/release-ci`, cut from master `7e8c9e6`.

The gap, restated: `.github/workflows/release.yml` published only
`ara-macos-arm64.tar.gz`. The landing page's `install.sh` prefers a DMG and
falls back to the tarball *without complaint*, so the next `v*` tag would have
handed users a bundle-less CLI — no `LSUIElement`, no
`NSMicrophoneUsageDescription`, no stable bundle identifier for TCC to file the
microphone grant under, and "Start at Login" pointing at the wrong binary — and
nothing anywhere would have said so.

Worth noting how thoroughly the workflow had never run: `gh release view v0.1.0`
lists exactly two assets, `Ara-0.1.0.dmg` and `Ara-0.1.0.dmg.sha256`. The
tarball the workflow was supposed to build is not there either. `gh run list`
shows only `pages-build-deployment` runs. This workflow has never executed once.

---

## 1. Runner facts, with citations

### The `runs-on` label that gives arm64

GitHub's runner reference lists the macOS images and their architectures:
`macos-latest`, `macos-14`, `macos-15` and `macos-26` are **arm64**;
`macos-15-intel` and `macos-26-intel` are the x64 variants.
(<https://docs.github.com/en/actions/reference/runners/github-hosted-runners>)

So the previous `runs-on: macos-15` was already arm64. That was not the problem.

### The problem was Swift, not Metal

`Package.resolved` pins `mlx-swift` at **0.31.6**. Its manifest opens:

```
// swift-tools-version: 6.3;(experimentalCGen)
```

(<https://raw.githubusercontent.com/ml-explore/mlx-swift/0.31.6/Package.swift>)

A toolchain older than Swift 6.3 does not fail late with a confusing link
error — it refuses to read the manifest. So the question is which image can
supply Swift 6.3. From Apple's own release notes (fetched from
`developer.apple.com/tutorials/data/documentation/xcode-release-notes/…`):

| Xcode | Swift | Host requirement |
|---|---|---|
| 26.0 | 6.2 | macOS Sequoia 15.6+ |
| 26.1.1 | 6.2.1 | macOS Sequoia 15.6+ |
| 26.2 | 6.2.3 | macOS Sequoia 15.6+ |
| 26.3 | 6.2.3 | macOS Sequoia 15.6+ |
| **26.4** | **6.3** | **macOS Tahoe 26.2+** |
| 26.5 | 6.3 | macOS Tahoe 26.2+ |
| 26.6 | 6.3 | macOS Tahoe 26.2+ |

Swift 6.3 first ships in Xcode 26.4, and Xcode 26.4 requires macOS Tahoe 26.2.
That combination can never exist on a macOS 15 host.

Confirming the macOS 15 image tops out below it — `images/macos/toolsets/toolset-15.json`:

```
default: 16.4
arm64:  ['26.3', '26.2', '26.1.1', '26.0.1', '16.4', '16.3', '16.2', '16.1', '16']
```

Newest available is Xcode 26.3 = Swift 6.2.3, and the *default* is Xcode 16.4
(Swift 6.1). The published `macos-15-arm64-Readme.md` agrees: `OS Version:
macOS 15.7.7 (24G720)`, `Xcode 16.4 (default)` at `/Applications/Xcode_16.4.app`.

**Conclusion: `macos-15` could not have built this package at all**, with or
without a Metal step. That is a more fundamental break than the one the issue
was filed about, and it would have surfaced as a manifest-parse error on the
first tag push.

`images/macos/toolsets/toolset-26.json`:

```
default: 26.6
arm64:  ['26.6', '26.5', '26.4.1', '26.3', '26.2', '26.1.1', '26.0.1']
```

and `macos-26-arm64-Readme.md` (image `20260720.0258.1`) reports `OS Version:
macOS 26.4 (25E246)` with Xcode 26.0.1 through 26.6 installed. Note the
disagreement — the toolset on `main` says the default is 26.6, the published
README snapshot shows 26.5 as default. Either satisfies Swift 6.3, and the
workflow does not depend on which: see §2.

### Xcode presence and the Metal toolchain

Xcode 26 **unbundled** the Metal toolchain. Local confirmation on this machine
(Xcode 26.6):

```
$ xcrun --find metal
/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.6.109.0.…/Metal.xctoolchain/usr/bin/metal
```

That path is a mounted MobileAsset cryptex, i.e. a separately downloaded
component, not something inside `Xcode.app`. Apple documents it under
"Downloading and installing additional Xcode components → Download and install
the Metal Toolchain", and the compiler's own error names the remedy:
`cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild
-downloadComponent MetalToolchain`.

Is it on the hosted runner? Yes, and by construction rather than by luck —
`images/macos/scripts/build/Install-Xcode.ps1`:

```powershell
$xcodeVersions | ForEach-Object {
    Invoke-XcodeRunFirstLaunch -Version $_.link
    Install-XcodeAdditionalSimulatorRuntimes -Version $_.link -Arch $arch -Runtimes $_.install_runtimes
    if ($_.link -match '^(\d+)\.(\d+)(?:\.(\d+))?$' -and [int]$matches[1] -ge 26) {
        Install-XcodeAdditionalComponents -Version $_.link
        Update-DyldCache -Version $_.link
    }
}
```

and `images/macos/scripts/helpers/Xcode.Installer.psm1`:

```powershell
function Install-XcodeAdditionalComponents {
    …
    Write-Host "Installing additional MetalToolchain component for Xcode $Version..."
    …
    Invoke-ValidateCommand "$xcodeBuildPath -downloadComponent MetalToolchain" | Out-Null
}
```

Every Xcode with major version ≥ 26 gets the Metal toolchain installed at image
build time. On `macos-26` that is *every* installed Xcode. On `macos-15` it
would cover 26.0.1–26.3 — which, per the table above, are the ones that cannot
compile the package anyway.

History for the record: it was **not** always so. `actions/runner-images#12856`
("Add Metal Developer Tools for macOS to macos-15 image") was closed with
`erik-bershel` initially declining ("this component can cause conflicts, so we
tend not to add it to the image centrally"), then `#13014` tracked the same
problem for macOS 26 and was fixed in week 40 of 2025, with the maintainer
pointing at `Install-Xcode.ps1#L38` as the implementation.

**It is not contractual.** `actions/runner-images#14013` ("MetalToolchain
component occasionally missing on macos-26 runners") was reproduced by a
maintainer at roughly **1 run in 50**. The workflow therefore probes and
repairs rather than assumes — see §2.

### Verdict on deliverable 2

The metallib step *can* work on a hosted runner, on `macos-26`, and the
workflow does not merely hope so: it proves `xcrun metal --version` succeeds
before building anything, repairs the known flake, and fails the job outright
if the repair does not take. Nothing publishes a DMG whose app would silently
degrade to rules-only formatting.

---

## 2. What the workflow now does, step by step

`runs-on: macos-26`, `timeout-minutes: 120`, job-level
`ARA_RELEASE_DIR=.build/arm64-apple-macosx/release` so `package-app.sh` reads
the real directory instead of relying on the `.build/release` symlink SwiftPM
happens to maintain.

1. **`actions/checkout@v4`.**

2. **`tag and VERSION must agree`** *(tags only)* — strips the leading `v` from
   `GITHUB_REF_NAME`, compares against a whitespace-stripped `VERSION`, fails
   naming both values. Runs first because it is the cheapest failure available.
   Also rejects an empty `VERSION`.

3. **`preflight — arm64, Swift 6.3, Metal compiler`** — three assertions:
   - `uname -m` must be `arm64`.
   - Walk the currently selected `DEVELOPER_DIR` first, then
     `/Applications/Xcode*.app/Contents/Developer` (deduplicated by realpath,
     since `/Applications/Xcode.app` is a symlink to the image default), pick
     the first providing Swift ≥ 6.3, and export it as `DEVELOPER_DIR` for the
     rest of the job. Trying the image's own selection first means CI stays on
     the blessed default whenever it suffices, which makes this robust against
     the toolset-vs-README disagreement noted in §1 and against future image
     rolls. If nothing qualifies, the job fails with a message saying so.
   - `xcrun metal --version` must succeed. If it does not, run `xcodebuild
     -downloadComponent MetalToolchain` and re-probe. If it still does not,
     fail — explicitly refusing to build a DMG that would degrade silently.

4. **`cache SwiftPM dependency sources`** — narrowed from `.build` to
   `.build/checkouts`, `.build/repositories`, `.build/artifacts` and
   `~/Library/Caches/org.swift.swiftpm`. This is a correctness change, not a
   tidy-up: caching all of `.build` also cached
   `.build/metallib-derived-data`, and `build-metallib.sh` skips its
   `xcodebuild` step entirely whenever a metallib already sits there. A
   `restore-keys` hit from an older cache — which is exactly what happens after
   a dependency bump changes the `Package.resolved` hash — would have paired a
   **stale metallib with a freshly built binary**. That is a kernel mismatch
   that shows up at runtime as degraded formatting, not as a build failure:
   precisely the class of quiet defect this whole task is about. Release builds
   are rare; the minutes are worth it.

5. **`build`** — `swift build -c release --arch arm64`.

6. **`stage the bare CLI`** — copies the binary to `dist/ara` and `strip -x`es
   it. Unchanged behaviour; the bundle uses the unstripped binary straight from
   `.build`, as it did for v0.1.0.

7. **`build the Metal kernel library`** — `scripts/build-metallib.sh`, which
   shells to `xcodebuild` and drops `mlx.metallib` into `$ARA_RELEASE_DIR`.

8. **`package Ara.app`** — `scripts/package-app.sh dist`.

9. **`package the DMG`** — `scripts/package-dmg.sh dist`.

10. **`verify the DMG ships a complete bundle`** — the guard whose absence made
    a bundle-less release possible. It mounts the finished image (not the
    staging directory — it tests the bytes that will actually be uploaded) and
    checks:
    - `Ara.app/Contents/MacOS/ara` exists and is executable;
    - `Ara.app/Contents/MacOS/mlx.metallib` exists and is **non-empty** (`-s`,
      not `-f`, so a zero-byte copy is caught);
    - `Info.plist` exists, its `CFBundleShortVersionString` equals `VERSION`,
      and it carries `LSUIElement`, `NSMicrophoneUsageDescription` and
      `CFBundleIdentifier` — the keys that are the entire reason to ship a
      bundle;
    - `codesign --verify` passes, because an app that is unsigned *as a bundle*
      is not "unsigned", it is invalid, and Gatekeeper calls it damaged.

    All checks run before the verdict, so one job log shows every problem, and
    the image is detached before the step exits either way.

11. **`checksums`** — builds the tarball, then writes both `.sha256` files in
    `shasum -a 256` format (`hash  basename`), which `shasum -c` accepts and
    which the live installer's `cut -d' ' -f1` reads happily. Note the existing
    v0.1.0 `.sha256` asset is a *bare* hash with no filename; the installer
    handles both, and the `shasum`-native format is strictly more useful.

12. **`release`** *(tags only)* — `softprops/action-gh-release@v2` uploading
    `ara-macos-arm64.tar.gz`, its `.sha256`, `Ara-*.dmg` and `Ara-*.dmg.sha256`,
    with `fail_on_unmatched_files: true` so a missing DMG is a failed release
    rather than a quiet tarball-only one. The tarball stays: `install.sh` still
    falls back to it and a bare CLI is legitimately useful.

`workflow_dispatch` runs everything except the version check and the upload, so
the whole packaging chain can be smoke-tested without cutting a release.

---

## 3. What was verified locally, and how

Everything below was exercised against the **exact text parsed out of
`release.yml`**, not a retyped copy, so the tests cannot drift from what ships.

- **YAML parses**, 12 steps, `runs-on: macos-26`, `timeout-minutes: 120`.
- **Every `run:` block passes `bash -n`.**
- **Every script the workflow calls exists and is executable**:
  `build-metallib.sh`, `package-app.sh`, `package-dmg.sh`.
- **Version-consistency logic**, 9 cases, all as expected: matching tag passes;
  `v0.2.0` against `VERSION=0.1.0` fails naming both; missing trailing newline
  passes; surrounding whitespace tolerated; a `VERSION` that wrongly carries the
  `v` fails; empty `VERSION` fails with its own message; `v0.1.0-rc1` against
  `0.1.0-rc1` passes.
- **`at_least()` version comparison**, 8 cases: `6.2.3 < 6.3` (the macos-15
  case) correctly rejected; `6.3`, `6.3.3`, `6.4`, `6.10`, `7.0` accepted;
  `6.1`, `5.9` rejected. `6.10 ≥ 6.3` matters — a naive string compare gets it
  wrong.
- **Preflight toolchain discovery run for real on this machine**: selected
  `/Applications/Xcode.app/Contents/Developer` → Swift 6.3, exactly once
  (dedupe works).
- **The Metal probe** the preflight gates on: `xcrun metal --version` →
  `Apple metal version 32023.883`.
- **The DMG guard, end to end against real artefacts.** I downloaded the
  published `Ara-0.1.0.dmg` and ran the guard verbatim against it, plus
  mutated rebuilds:

  | image | result |
  |---|---|
  | real published `Ara-0.1.0.dmg` | **passes**, all four checks green |
  | rebuilt, unmodified (control) | **passes** |
  | `mlx.metallib` removed | **fails**, correct message |
  | `mlx.metallib` truncated to zero bytes | **fails** |
  | `Contents/MacOS/ara` removed | **fails** |
  | `Info.plist` version changed to 9.9.9 | **fails**, names both versions |

  The control case matters: it proves the guard is not simply rejecting
  anything rebuilt. (It also cost me a false positive — a `shutil.copytree`
  round-trip invalidates the ad-hoc signature because it does not preserve the
  sealed modes and xattrs; `ditto` does.)

- **`scripts/install.sh`** passes `bash -n`, stays executable, prints the
  canonical URL and exits 1.
- **`swift test`**: 480 tests, 0 failures. No Swift was touched.

## 4. What remains unverified until a real tag is pushed

Named plainly, because the whole point of this change is not to paper over
quiet failure:

1. **No run of this workflow has ever happened**, including this version of it.
   Every gate is proven in isolation; none has been proven *on a GitHub
   runner*.
2. **Wall-clock cost is an estimate.** The job builds the package twice — once
   through SwiftPM for the release binary, once through `xcodebuild` inside
   `build-metallib.sh` for the shaders SwiftPM cannot compile — over the
   WhisperKit + MLX dependency graph. 120 minutes is a guess with margin, not a
   measurement. macOS runner minutes bill at 10×, so the first real tag is also
   the first real cost signal.
3. **`xcodebuild build -scheme ara` against a bare `Package.swift` on a hosted
   runner** is unexercised here. It works locally; scheme auto-discovery from a
   SwiftPM manifest under a fresh derived-data path on CI is not something I
   could test.
4. **The Metal toolchain repair path** (`xcodebuild -downloadComponent
   MetalToolchain` on a runner that lost it) has never fired — the ~1/50 flake
   did not reproduce, and it cannot be induced locally. Whether it needs `sudo`
   in the runner's environment is unconfirmed; it is invoked unelevated,
   matching what Apple's own error message tells you to run.
5. **Which Xcode the image actually defaults to** is a moving target — the
   toolset on `main` and the published README snapshot disagree (26.6 vs 26.5).
   The preflight is written not to care, but "not to care" is itself untested
   against a live image.
6. **`ara --version` from inside the built bundle is not asserted.** The guard
   checks `Info.plist`'s `CFBundleShortVersionString` instead. Executing the
   binary on a headless runner risks a hang for a check that would only confirm
   the plist read-back path.
7. **The published assets have not been fed to the real `install.sh`.** The DMG
   name, the `.sha256` format and the fallback ordering all match what the live
   installer parses — read directly from
   <https://karniej.github.io/ara-parrot/install.sh> — but end-to-end
   download-and-install is untested.

## 5. How the `install.sh` divergence was resolved

**Made a pointer, not synced.** Justification:

There were two copies. The canonical one is served from gh-pages at
`https://karniej.github.io/ara-parrot/install.sh`; it is what the README
documents (twice), it is what users actually run, and it is where the work
happens. The copy at `scripts/install.sh` had fallen behind: tarball-only, no
checksum verification at all, `/usr/local/bin` via `sudo`, while the canonical
one had learned to prefer the DMG, verify the published `.sha256`, strip
quarantine from the whole bundle, and install per-user without escalating.

Nothing in the repo references `scripts/install.sh` — I grepped the README and
all of `docs/`. Its only inbound path was the `raw.githubusercontent.com/…/master/scripts/install.sh`
URL advertised in its own header comment.

Syncing would produce two byte-identical files with no mechanism keeping them
that way, which is exactly the arrangement that produced the drift: the landing
page work edited gh-pages and had no reason to touch `scripts/`. The next
landing-page change re-opens the same gap. A pointer has no drift surface.

It fails loudly — prints the canonical one-liner and exits 1 — rather than
redirecting silently or `curl | sh`-ing on the user's behalf. Someone still
piping the stale master URL into `sh` now gets told where to go, instead of
quietly receiving a bundle-less CLI installed to a sudo-owned directory. That
is the same principle as the rest of this change: a loud stop beats a silent
downgrade. The file also keeps a short from-source build recipe in its header
for anyone who lands on it while browsing the repo.

## 6. Commits

```
b4de215  ci: build and publish the app bundle on a tag
7532f60  docs: make scripts/install.sh a pointer, not a stale second installer
989400d  docs: mark the release-workflow gap resolved, and record what remains
```

## 7. Concerns worth a maintainer's attention

- **The macos-15 → macos-26 move is load-bearing and was not in the brief.**
  The task framed the metallib as the awkward part. It is not; the Swift
  toolchain is. Had the runner label stayed at `macos-15`, the first tag push
  would have failed on manifest parsing before reaching any packaging step.
- **Double build cost.** Two full compiles of the MLX/WhisperKit graph per
  release. If the first real tag runs long, the fix is to teach
  `build-metallib.sh` to build a narrower scheme than `ara` — but that is a
  script change, out of scope here.
- **The DMG stays unsigned and unnotarized.** Out of scope, unchanged, and
  already documented in the README's "Unsigned builds"; the guard verifies the
  *ad-hoc* signature only. Users still need the quarantine strip that
  `install.sh` performs.
- **`VERSION` is still bumped by hand.** The workflow now catches a
  tag/`VERSION` mismatch, which is the failure that matters, but nothing stops
  someone from tagging `v0.2.0` without bumping — they just get a red build
  instead of a mislabelled release. That is the correct trade, but it is a
  trade.
