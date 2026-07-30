# Ara DMG packaging — implementation report

Branch `feature/dmg-packaging`, from `919ffc5`. Five commits. 478 tests green
(467 at base, +11 new), `swift build -c release` green.

## The metallib layout, and the evidence

**Verified layout: `Ara.app/Contents/MacOS/mlx.metallib` — beside the
executable, *not* in `Contents/Resources/`.**

### Why, from the source

MLX resolves its kernel library against the **binary**, not the bundle.
`mlx/backend/common/utils.cpp`:

```cpp
std::filesystem::path current_binary_dir() {
  ...
  if (!dladdr(reinterpret_cast<void*>(&current_binary_dir), &info)) {
```

`Cmlx` is statically linked into `ara`, so `dladdr` on MLX's own code resolves
to the `ara` executable, and `current_binary_dir()` is the directory containing
it. `mlx/backend/metal/device.cpp`, `load_default_library`, then tries in
order:

1. `<binary dir>/mlx.metallib`
2. `<binary dir>/Resources/mlx.metallib`
3. the SwiftPM `mlx-swift_Cmlx.bundle` lookups
4. `<binary dir>/Resources/default.metallib`
5. the compiled-in `METAL_PATH`

Inside an app bundle `<binary dir>` is `Contents/MacOS`. So candidate 1 is
`Contents/MacOS/mlx.metallib` (a hit) and candidate 2 is
`Contents/MacOS/Resources/mlx.metallib`. `Contents/Resources/mlx.metallib` is
one level up from anything the loader inspects and is never reached.

### Empirical confirmation, both directions

Ran the packaged binary against the real loader (not the `Doctor` heuristic) —
`Ara.app/Contents/MacOS/ara run --skip-doctor --no-overlay`, formatting model
already on disk, killed as soon as warm-up reported.

**Metallib in `Contents/MacOS/` (shipped layout):**

```
loading whisper-base.en...
loading mlx-community/Qwen2.5-1.5B-Instruct-4bit (formatting — the first run can take a while)...
✓ mlx-community/Qwen2.5-1.5B-Instruct-4bit ready (2.5s)
```

**Same file moved to `Contents/Resources/`, nothing else changed:**

```
loading mlx-community/Qwen2.5-1.5B-Instruct-4bit (formatting — the first run can take a while)...
✓ whisper-base.en ready
! local formatting unavailable: this build has no Metal kernel library (mlx.metallib) — `swift build` cannot compile one; run `scripts/build-metallib.sh` ...
  dictation will use rule-based cleanup until then
listening on fn hold · model: whisper-base.en · ^C to quit
```

That second run is exactly the silent degradation the brief warned about: the
app launches, arms the hotkey, and types text — just rule-cleaned. Nothing
about it looks broken from the outside.

`ara doctor` run from the shipped bundle also reports
`✓ local formatting model: ok` with no metallib warning, so
`MLXRuntime.locatedMetallib`'s heuristic agrees with the real loader for the
bundle layout — its first candidate is
`Bundle.main.executableURL.deletingLastPathComponent()/mlx.metallib`, which is
`Contents/MacOS/mlx.metallib`. No change was needed there.

`package-app.sh` re-asserts the file's presence after assembly and fails if it
is not there.

## Version source

**A `VERSION` file at the repository root**, currently `0.1.0`.

Chosen over a git tag because tags are absent from source tarballs and from
shallow CI clones, and a packaging script keyed on `git describe` produces
`Ara-.dmg` on such a checkout — a broken artefact rather than a clear failure.
A file is always present and can be validated in one line.

The chain has exactly one number in it:

```
VERSION → package-app.sh → Info.plist CFBundleShortVersionString / CFBundleVersion
                        → package-dmg.sh → Ara-0.1.0.dmg
                        → AraVersion.string(from: Bundle.main.infoDictionary) → `ara --version`
```

Nothing in Swift duplicates the number, so nothing in Swift can disagree with
the file. A `swift build` binary has no bundle and therefore no version; it
reports `source build (unversioned)` rather than a literal that would pin bug
reports to the wrong commit. Verified:

```
$ cat VERSION                                    0.1.0
$ dist/Ara.app/Contents/MacOS/ara --version      0.1.0
$ .build/release/ara --version                   source build (unversioned)
$ ls dist/                                       Ara.app  Ara-0.1.0.dmg
```

`AraVersion.string(from:)` is pure and unit-tested (5 cases: present, nil
dictionary, empty dictionary, blank/whitespace value, non-string value,
whitespace trimming).

## Icon

**Produced.** `packaging/Ara.icns`, 540 KB, built by `scripts/build-icon.sh`
from `docs/assets/ara.png` with `sips` + `iconutil` only.

The banner is 1774×887 — macaw on the left, waveform and "Ara" wordmark on the
right. A centred square crop would have been the letter "A". The script instead
crops the macaw's measured bounding box (`x 300..725, y 145..775`, which
includes the branch reaching further left than the body and the full tail
reaching nearly to the bottom edge) with `sips -c ... --cropOffset`, then pads
that portrait rectangle to 740×740 with the banner's own black
(`sips -p --padColor 000000`), upscales once to a 1024 master so every icon
size is a downsample of the same image, and packs the ten standard iconset
sizes. Visually checked at 256px: bird centred, fully inside the frame, no
wordmark, no cropped tail.

The `.icns` is committed so packaging does not depend on regenerating it.
`package-app.sh` copies it to `Contents/Resources/Ara.icns` and emits
`CFBundleIconFile` only when the file exists — a checkout without it still
produces a working app with the generic macOS icon, and says so on stderr.

## `resolveBinaryPath` inside a bundle

**Before:** it returned `/usr/local/bin/ara` unconditionally whenever that path
was executable, consulting `argv[0]` only as a fallback. Running from inside
`Ara.app`, on any machine that had ever installed the CLI, "Start at Login"
therefore wrote a plist pointing at the loose binary.

That is not a cosmetic difference. The loose binary has no Info.plist, so:
no `LSUIElement` (it would run as a foreground app), no
`NSMicrophoneUsageDescription`, and — the one that actually breaks things — a
different TCC identity. macOS files microphone and Accessibility grants against
`com.silpho.ara` for the bundle and against the launching process for a bare
executable, so the login agent would be a program the user never granted
anything to. On a machine upgrading from the CLI-only era it is also an older
build.

Without a `/usr/local/bin/ara` present the old code would have fallen through
to `argv[0]`, which under Finder *is* the bundle's executable — so the defect
only bit users who had both. That is precisely the upgrade path this release
creates.

**After:** the decision moved to a pure `Install.launchAgentBinary(
runningExecutable:argv0:isExecutable:)`, with `Install.isInsideAppBundle(_:)`
alongside it:

1. running executable, if it is inside a `.app` bundle and executable → use it
2. else `/usr/local/bin/ara`, if executable
3. else `argv[0]`, if absolute and executable (a relative `argv[0]` is refused —
   it would resolve against launchd's working directory, not the user's)
4. else `nil` → the command exits 1 with a message naming both install paths

`isInsideAppBundle` checks the path structurally (last three components are
`<name>.app / Contents / MacOS`), not by substring, so `/opt/notanapp/Contents/
MacOS/ara` is not mistaken for a bundle. Six unit tests cover the ordering
(including "bundle beats a present canonical install") and six cover the
structural detection.

Outside a bundle the previous order is unchanged: the canonical install still
beats a `.build/release/ara`, whose path stops existing the moment the checkout
moves.

`SMAppService` was not touched, per the file's header comment.

## Signing commands documented (not run)

Nothing was signed, no certificate was created, the keychain was not touched.
The README's new "Unsigned builds" section documents, for a maintainer who has
a Developer ID:

```sh
scripts/package-app.sh
codesign --deep --force --options runtime --timestamp \
    --sign "Developer ID Application: NAME (TEAMID)" dist/Ara.app
scripts/package-dmg.sh                       # rebuild the image around the signed app
xcrun notarytool submit dist/Ara-<version>.dmg \
    --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple dist/Ara-<version>.dmg
```

with the note that the DMG must be rebuilt between signing and submission (an
image built around the unsigned app stays unsigned however `dist/Ara.app`
changes afterwards), and that `--options runtime` is both required for
notarization and what makes the entitlements attach to the bundle.

For the downloader, the same section documents what unsigned means: Gatekeeper
refuses the first launch of a quarantined, unsigned, unnotarized app with
"damaged" or "developer cannot be verified" (neither of which is true);
**right-click → Open → Open** records consent once; or
`xattr -d com.apple.quarantine /Applications/Ara.app`. It also points at the
`sha256` `package-dmg.sh` prints, since a checksum is the only integrity check
an unsigned download has.

## Commits

| | |
| --- | --- |
| `2397452` | give the build a version with exactly one source |
| `a123e1c` | point the launch agent at the bundle when ara runs from one |
| `ef9b0fa` | draw the app icon from the README banner |
| `7fe41d8` | package ara as a double-clickable app in a dmg |
| `16392ab` | document the dmg install, unsigned builds, and how to verify a bundle |

## Concerns

- **Nothing double-clicked.** Everything here was driven from a shell. The
  Finder launch, the Gatekeeper dialog, the microphone prompt's wording, the
  absent Dock icon, and a real login cycle are all in
  `docs/MANUAL-VERIFICATION.md` §9octies as unchecked boxes. The two boxes
  marked `[x]` (metallib layout, version chain) were genuinely observed.
- **`ara run` under Finder gets no arguments and no visible stderr.** A
  double-clicked bundle runs `Run` with the doctor gate active and every
  diagnostic going to a stderr nobody reads. If a permission is missing the app
  may appear to do nothing. Out of scope here, but it is the first thing a real
  first-run test will hit.
- **The DMG is a plain drag-install window** — no background image, no icon
  positioning, no window size. `hdiutil` alone gives a Finder list view. Making
  it pretty needs an AppleScript pass over the mounted volume, which is a
  separate piece of work.
- **`scripts/install.sh` still installs the bare binary** from a release
  tarball that no release produces yet. It is now the secondary route in the
  README, but if the first release ships only a DMG, that script's asset name
  (`ara-macos-arm64.tar.gz`) has nothing to fetch. Someone has to decide
  whether releases carry both artefacts.
- **Bundle size is 44 MB**, 12 MB compressed — 3.8 MB of that is the metallib
  and the rest is the statically linked binary. Fine, but note the ~900 MB
  formatting model is still a separate post-install download; the DMG is not a
  complete install on its own.
