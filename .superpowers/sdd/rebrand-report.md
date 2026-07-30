# Rebrand: parrot → Ara

Branch `feature/rebrand-ara`, from master tip `7996c9b`. Three commits, 467
tests green (460 at base, +7 for the migration), `swift build -c release`
green, binary verified at `.build/release/ara`.

## What was renamed

**Build and entry point.** `Package.swift` package name and executable target
→ `ara`. `Sources/parrot/` → `Sources/ara/`, `Parrot.swift` → `Ara.swift`,
`@main struct Parrot` → `Ara`, `commandName: "parrot"` → `"ara"`. The library
target was already `AraCore` before this work.

**User-visible strings.** Every abstract and `help:`, every stderr line, every
`print`, every doctor remediation, the menu's `Quit Ara` and its
model-download alert, `Setup`'s whole transcript, `MLXModel.downloadCommand`,
and the `run \`ara setup\`` / `run \`ara models list\`` error paths.

**Identifiers and paths.** LaunchAgent label `com.digimata.parrot` →
`com.silpho.ara`. Canonical install path `/usr/local/bin/parrot` →
`/usr/local/bin/ara`. `--dump-wav` target `/tmp/parrot-last.wav` →
`/tmp/ara-last.wav`, with its KNOWN-ISSUES entry (including the proposed fix
location, `~/Library/Caches/ara/`).

**Test env vars.** `PARROT_AUDIO_HW` → `ARA_AUDIO_HW`, `PARROT_MLX_BENCH` →
`ARA_MLX_BENCH`, plus `PARROT_METALLIB_DD` → `ARA_METALLIB_DD` in
`scripts/build-metallib.sh`. Every doc naming them moved in the same commit:
`docs/MANUAL-VERIFICATION.md` (two sites), the two test files' own doc
comments, and `MLXFormatter`'s class doc.

**Build artefacts.** `.github/workflows/release.yml` stages
`.build/arm64-apple-macosx/release/ara` and ships `ara-macos-arm64.tar.gz` —
this would have broken outright otherwise, since SwiftPM's product name
follows the target. `scripts/build-metallib.sh` now passes `-scheme ara` and
looks for `araPackageTests.xctest`, both of which SwiftPM derives from the
package name.

**Docs.** README (whole file bar the fork attribution), `docs/architecture.md`
(including `ParrotCLI` → `AraCLI`), `docs/KNOWN-ISSUES.md`,
`docs/MANUAL-VERIFICATION.md`, `scripts/install.sh`,
`scripts/cleanup-eval/README.md`.

## What was deliberately left alone

**`LICENSE`** — untouched, byte for byte. It contains no occurrence of
"parrot" to begin with; the constraint held for free. The README keeps its
fork attribution to [digimata/parrot](https://github.com/digimata/parrot).

**Legacy log filenames.** `LegacyLogs.defaultPaths` stays
`["/tmp/parrot.out.log", "/tmp/parrot.err.log"]`, and so do the fixtures in
`InstallTests`/`DoctorTests` that name them. These are files already on users'
disks, written by builds that shipped as `parrot`; renaming them would leave
the privacy cleanup hunting for files nobody has while the real ones go on
leaking. A doc comment on `defaultPaths` says exactly that, addressed to the
next rename sweep. `--purge-legacy-logs`' help text keeps the old filenames
for the same reason — it is naming what it deletes.

**Dictionary test fixtures.** `LocalDictionaryTests` uses `Parrot`/`parat` as
a second canonical alongside `Ara`/`arra`. That is arbitrary vocabulary data
chosen to be distinct from `Ara`, not branding — renaming it would collide two
entries and change what the merge tests actually test.
`LocalDictionary.swift:448`'s comment references the same fixture scenario and
was left consistent with it. Likewise `docs/MANUAL-VERIFICATION.md` step 8b's
"heard `parrot`, should be `Parrot MAX`" is a word chosen because Whisper
mishears it reliably; it is dictation content, not a product name.

**Everything under `docs/superpowers/`, `.plan/plan.md`, and the other
`.superpowers/sdd/*.md` reports.** These are past-tense records of completed
work. Their `parrot` mentions are statements about what the tool was called at
the time — one of them (`2026-07-29-ara-formatting-core.md:19`) says outright
"Binary is still `parrot`. The rebrand is a separate project", which is now
the accurate history of *this* branch. Every command in them belongs to a task
that has already been performed (`git mv Sources/parrot/…`, a build-and-check
step from a finished task), so none of them is a command someone would run
today. I changed nothing there. The one entry I went back and forth on is
`.superpowers/sdd/cleanup-parity-report.md:125`, which records a
`PARROT_MLX_BENCH=1 swift test` invocation that would now silently no-op if
re-run; I left it, because rewriting it would falsify a record of what was
actually executed. It is listed under "unsure" below.

## The migration

The label move orphans every existing install: `com.digimata.parrot` and
`com.silpho.ara` are unrelated to launchd, so an agent bootstrapped under the
old label keeps `RunAtLoad`-ing the old binary at every login. A user who then
enabled Start at Login would get two daemons fighting over the hotkey, with
nothing in the new build naming the other one.

- `Install.legacyLabel` / `Install.legacyPlistURL` pin the old identity. The
  old path was confirmed from the current code — `plistURL` composed
  `~/Library/LaunchAgents/<label>.plist`, so both URLs now come from one
  `agentPlistURL(for:)` helper and differ only in the label.
- `Install.removeLegacyAgent(at:bootout:)` boots the old agent out **while its
  plist still exists**, then deletes the file, returning the path removed or
  `nil` when there was nothing there. The ordering is load-bearing: `launchctl
  bootout` takes the plist's *path*, so unloading a deleted agent tells launchd
  nothing and the old daemon would run until the next reboot with nothing on
  disk to explain it. The test pins the ordering by stat-ing the file from
  inside the injected bootout closure.
- `installAgent()` calls it before writing the new plist, printing
  `✓ removed the pre-rename launch agent (<path>)`. Best-effort throughout: a
  refused bootout and an undeletable plist are stderr lines, not a failed
  install.
- `uninstallAgent()` removes both. Otherwise "remove launch-at-login" would
  stop the daemon and have it return at the next login under a name this build
  never mentions. Its "nothing to remove" line is suppressed when a legacy
  agent *was* removed, so the output never contradicts itself.
- `DoctorReport.checkLegacyLaunchAgent(plistPath:)` warns while a pre-rename
  plist exists, naming the path and the second-daemon consequence, with the
  re-install as the remediation (nothing to delete by hand). It follows
  `checkLaunchAgentLogPaths`/`checkLegacyLogs` exactly: a defaulted path
  parameter for testability, and a **warning, never a failure**, because `Run`
  gates startup on `allOK`.

TDD: the seven new tests were written first and confirmed red (compile
failure on the missing members) before any implementation. They use real
temp-directory plists, matching the house style of the surrounding suites.

`docs/MANUAL-VERIFICATION.md` gains step **9sp-f-bis**, the part only a real
machine can prove: fake an old agent, bootstrap it, watch two daemons answer
the hotkey, then confirm `ara doctor` flags it and
`ara install --launch-at-login` clears it out of launchd.

README gains an **Upgrading from `parrot`** section: the daemon story above,
the symlink one-liner
(`ln -sf "$(pwd)/.build/release/ara" ~/.local/bin/ara && rm -f ~/.local/bin/parrot`),
and the explicit statement that `~/.config/ara/` plus `dictionary.json` and
`snippets.json` are unchanged — they were already under `ara/` before this
work, so there is nothing to migrate.

## Occurrences I was unsure about

1. **`scripts/install.sh` repo coordinates.** `REPO` was `digimata/parrot` and
   the documented one-liner was `https://digimata.github.io/parrot/install.sh`
   — both pointing at *upstream*. Since `.github/workflows/release.yml` lives
   in this repo and now produces `ara-macos-arm64.tar.gz`, leaving `REPO` on
   upstream would make the installer fetch an asset that does not exist there.
   I set `REPO="Karniej/ara-parrot"` and `ASSET="ara-macos-arm64.tar.gz"` from
   `git remote -v` (the `fork` remote), and replaced the GitHub Pages one-liner
   with `https://raw.githubusercontent.com/Karniej/ara-parrot/master/scripts/install.sh`
   because I cannot verify Pages is configured for the fork. **Confirm both**
   — the repo slug, the default branch name, and whether the repo is public.
   The README's fork note was rewritten to say the installer has nothing to
   fetch until a tagged Ara release ships, which is the current truth.

2. **The Keychain service id.** `Keychain.swift` uses `com.digimata.ara` —
   already half-renamed before this work, and outside the brief. I left it.
   Changing it would orphan any stored cloud API key with no migration path,
   and unlike the LaunchAgent there is no double-daemon failure mode forcing
   the issue. `docs/MANUAL-VERIFICATION.md:388`'s
   `security add-generic-password -s com.digimata.ara` matches it. Worth a
   follow-up decision, with the same
   read-old-then-write-new dance the agent got.

3. **`.superpowers/sdd/cleanup-parity-report.md:125`** — the historical
   `PARROT_MLX_BENCH=1 swift test` line discussed above. Left as a record; flag
   if you'd rather historical reports stay runnable.

4. **`docs/architecture.md` staleness.** It is a design doc that predates the
   current code: it describes `main.swift`, a single executable target, a
   `~/.config/<name>/config.toml`, and a `ParakeetTranscriber` that does not
   exist. I renamed straight through it (so the config path now reads
   `~/.config/ara/config.toml` — right directory, wrong file format) rather
   than fix staleness the brief did not ask for. That staleness predates this
   branch, but it is now stale under a new name.

## Commits

- `1ddd48f` rename the package, binary, and every user-visible string to ara
- `4b50a4c` clear the pre-rename launch agent on install and uninstall
- `a3ca261` document the upgrade path from parrot

## Verification

```
swift test                 → 467 tests in 35 suites, all passed
swift build -c release     → Build complete
.build/release/ara --help  → USAGE: ara <subcommand>
.build/release/ara doctor  → 7 checks, incl. "✓ legacy launch agent: ok"
.build/release/ara dictionary → prints ~/.config/ara/dictionary.json + entries
```

The Install plist test that pins `ProgramArguments` against
`--echo-transcripts` still passes: the binary path inside it moved to
`/usr/local/bin/ara`, the assertion did not.
