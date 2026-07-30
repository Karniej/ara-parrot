# Menu parity — report

Branch `feature/menu-parity` off master tip 07bb16d.

## Status

Complete. All six deliverables shipped on the house pattern (pure tested
menu models, thin `MenuBarController` shells, `rewriteOneKey` persistence,
by-value MainActor sampling in `Run`).

## Commits

1. `2c616f0` feat: persistModel, persistHotkey, persistEngine — the menu's one-key rewrites
2. feat: pure submenu models for Model, Hotkey, Engine, and Mode (+ `Engine: CaseIterable`, `Hotkey: Sendable`)
3. feat: DoctorReport.rendered and the Install helpers the menu needs (`installAgent`/`uninstallAgent`/`isInstalled`, all static; plist content untouched — the never-echo-transcripts test still passes)
4. feat: menu doors to model, hotkey, engine, mode, login, and diagnostics (controller shells + Run wiring, `ManualMode` MainActor box sampled by value at the frontmost-app sample point)
5. docs: the menu bar's full map (README, before Configuration) and the 9septies hand-checks

## Tests

458 tests in 34 suites pass (434 at base + 24 new: 6 persist, 14 menu-model,
1 doctor-rendered, 1 install-isInstalled, plus suite splits); `swift build
-c release` green; `parrot models list` / `parrot install` smoke-checked.
TDD failing-first throughout (each test batch confirmed failing to compile
or run before implementation).

## Key decisions

- **Cloud "(no API key set)" suffix: implemented, without any keychain
  read from the menu.** `Keychain.readPassword`'s doc warns the read can
  raise a blocking unlock/Allow-Deny prompt — for this unsigned binary the
  re-prompt is the *normal* path, so a menu-context read was disqualified.
  Instead `Run`'s existing once-at-startup read is reused: `hasAPIKey =
  (apiKey != nil)` is carried by value into `EngineMenuModel.compute`. This
  is also the honest value — the once-per-process read means the running
  daemon will never use any key added later. When `config.cloud` is absent
  no read ever happened and the suffix shows, which matches reality: the
  daemon has no key.
- **Doctor keychain: non-issue, verified.** `DoctorReport.run()` contains
  no keychain check at all — its checks read AVCaptureDevice authorization
  status (no prompt), `AXIsProcessTrusted` (the non-prompting variant),
  spawn `defaults`/`ps`, and stat the model/metallib/plist/log files. It is
  run via `Task.detached` because of the process spawns and disk I/O; only
  the rendered string hops to the MainActor alert.
- **Mode is the one live pick and is never persisted** — session override
  by design; `config.mode` stays the startup default (doc'd in
  `ModeMenuModel`, README, and Run). Sampled by value in the released
  handler at the exact point `frontmostBundleID` is sampled.
- **Formatter download is an alert with the exact command + Copy button**
  (`parrot models download-formatter`), never an in-process 900 MB fetch.
- **Start at Login**: checkmark is always `Install.isInstalled()` re-read
  from disk after success *and* failure. Verified against `Install`:
  `RunAtLoad` + `launchctl bootstrap` starts the login copy **immediately**,
  so the post-enable notice says "has started now … quit the terminal one —
  two daemons would both respond to the hotkey" rather than the spec's
  draft "starts at next login" wording.
- **Restart-bound checkmarks follow the cleanup precedent**: the check
  moves only when the pick actually landed in the file; a failed write
  keeps the old check and warns on stderr.

## Concerns / follow-ups

- Hotkey live re-arm is documented as a known follow-up (upstream PR #7);
  the submenu caption stays "applies on restart".
- `Install.installAgent()` failure surfaces `String(describing: error)` in
  the alert; for `resolveBinaryPath`'s `ExitCode(1)` the richer explanation
  goes to stderr, which a menu-only user cannot see. Cosmetic; noted in
  case a friendlier error type is wanted later.
- 9septies checks are unrun (no human at the keyboard here), like the rest
  of MANUAL-VERIFICATION.
- Pre-existing warning (`PasteInjector.swift:140` main-actor `warnToStderr`)
  untouched — present at base.
