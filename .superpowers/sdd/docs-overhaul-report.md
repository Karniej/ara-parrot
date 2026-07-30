# Docs overhaul: what the old docs claimed, and what the code does

Branch `feature/docs-overhaul` off `8c4063d`. Two commits, both docs-only.
Zero Swift, script, `Package.swift` or `VERSION` changes — `git diff --name-only
8c4063d HEAD` returns exactly `README.md` and `docs/architecture.md`.
`swift test`: **478 tests in 37 suites, all passed** (0.856 s).

Every claim below was checked against the source named beside it. Where the doc
and the code disagreed, the code won.

---

## `docs/architecture.md` — stale, not merely incomplete

The file was a pre-implementation planning document that shipped and was never
revisited. It described a program that does not exist. Rewritten from scratch.

| Old claim | What the code does | Source |
|---|---|---|
| Entry point is `main.swift` | `@main struct Ara: ParsableCommand` in `Sources/ara/Ara.swift` | `Sources/ara/Ara.swift:6` |
| "One Swift Package executable target", "single SPM executable target", "everything is in the same module so no `import` statements between files" | Two shipping targets — the `AraCore` library and the `ara` executable — plus the `AraCoreTests` test target. `Ara.swift` opens with `import AraCore` | `Package.swift` |
| Config is `~/.config/ara/config.toml`, with a TOML example | `~/.config/ara/config.json`, decoded with `JSONDecoder` | `Config.defaultURL`, `Config.load` |
| Config key `overlay = true` | No such key. `CodingKeys` are `engine, timeoutMs, mode, hotkey, model, cloud, microphone, inject, pasteRestoreMs, cleanup`. The pill is controlled by the `--no-overlay` flag only | `Config.CodingKeys`, `Run.noOverlay` |
| `ParakeetTranscriber` wraps FluidAudio (or direct CoreML) for NVIDIA Parakeet TDT; "Adding an engine = one new file conforming to `Transcriber`" | The type does not exist. `WhisperKitTranscriber` is the only conformance. `TranscriptionEngine` has a `.parakeet` case that no registry entry uses and no transcriber implements | `Sources/AraCore/Transcription/`, `Models/TranscriptionModel.swift` |
| A `ModelDownloader` type downloading to `~/Library/Application Support/ara/models/<engine>/<id>/` | No such type. WhisperKit downloads inside its own `WhisperKit(config)` init; MLX downloads via `MLXModel.download`. Both share the HuggingFace hub cache, `~/Documents/huggingface/models/<org>/<repo>` by default | `WhisperKitTranscriber.warmUp`, `MLXModel.hub`/`.directory` |
| "Backed by a bundled `models.json` resource" | `ModelRegistry.shared` is a hardcoded Swift array. Its doc comment states the reason: "The model list lives directly in source rather than as a JSON resource so the binary stays self-contained" | `Models/ModelRegistry.swift:3-7` |
| `enum Engine { case whisperKit, parakeet }` presented as *the* Engine enum | Two unrelated enums. `TranscriptionEngine` (whisperKit/parakeet) tags a model; `Engine` (mlx/apple/cloud/rules/off) selects a *formatting* engine and is the one in `config.json` | `Models/TranscriptionModel.swift`, `Config/Config.swift` |
| Model table: `whisper-base.en` ~80 MB, `whisper-large-v3-turbo` ~800 MB, `parakeet-tdt-0.6b-v3` ~600 MB | `whisper-base.en` 145 MB, `whisper-large-v3-turbo` 1620 MB, `whisper-small.en` 488 MB. No parakeet entry. Confirmed against live `ara models list` | `ModelRegistry.shared` |
| "Refuses to start the daemon if the selected model isn't present" | Warm-up downloads it. A failed *transcriber* warm-up is fatal; a failed *formatter* warm-up is a warning and the daemon runs on the rules floor | `Ara.swift` warm-up `Task.detached` |
| Subcommands are `ara`, `models list`, `models download`, `doctor` | Also `setup`, `install` (three flags), `dictionary`, `snippets`, `models download-formatter` | `Ara.configuration.subcommands` |
| Non-goals: "Menubar, dock icon, settings window, preferences UI"; "The only UI is the recording overlay" | `MenuBarController` is 603 lines with six submenus, two file-opening items, a correction form, a login toggle, and a diagnostics window. Its own doc calls it "the only persistent control surface for the daemon" | `UI/MenuBarController.swift` |
| Non-goals: "Auto-launch at login (user wires this themselves with `launchd` if desired)" | `ara install --launch-at-login` writes and bootstraps the plist; the menu has a **Start at Login** toggle running the same code | `Install.installAgent` |
| Non-goals: "AI post-processing, summarization"; "No custom vocabulary, prompts, or post-processing" | The formatting chain, `TranscriptPrompt`, `LocalDictionary` and `Snippets` are all shipped features | `Formatting/`, `Vocabulary/` |
| "Two prompts on first run, both surfaced via `ara doctor`" | `DoctorReport.run()` returns **eight** checks | `Doctor.run()` |
| "Without these, the daemon refuses to start" (of both permissions) | `Run` gates on `allOK`, which is false only on a `.fail`. Three checks can hard-fail (microphone, accessibility, Fn key mapping); the other five only warn | `DoctorReport.allOK`, `Run.run()` |
| "End-to-end latency target: <500 ms after hotkey release for utterances under 10 seconds" | Not achieved and not the design. Measured: 2.89 s of audio → 1.33 s transcription with `whisper-base.en`; MLX formatting 787 ms median on top | formatting-layer design spec line 26; `MLXFormatter` doc |
| "Project layout (planned)" tree | Matches no directory in the repo — it omits `Session/`, `Modes/`, `Formatting/`, `Vocabulary/`, `Config/`, and the `AraCore`/`ara` split, and includes a `Resources/models.json` that does not exist | `Sources/` |
| Open question: "Code signing… Decide if we sign" | Decided and shipped: `package-app.sh` ad-hoc signs the metallib then the bundle, and verifies | `scripts/package-app.sh:140-167` |

Also removed: the ASCII diagram routing `Transcriber → TextInjector` directly
(there is a whole session, dictionary, snippets, mode and formatter layer in
between), and the claim that the `RecordingOverlay` is "the only reason the
process needs an `NSApplication` run loop" (the status item and the alerts need
it too).

---

## `README.md` — under-sold, and wrong in eight places

Restructured, not merely edited. The factual corrections:

| Old claim | What the code does | Source |
|---|---|---|
| `ara setup` — "one-time setup: permissions + model download" | `Setup.run()` calls `waitForAccessibility()` and `waitForMicrophone()`. It downloads nothing and mentions no model | `Setup.swift` |
| "The transcript types itself in at the cursor when you release. Usually within 200-300ms." | Never measured, and the project's own design spec says so in as many words: "The README's '200-300 ms' claim is not accurate." Real numbers: 1.33 s transcription for 2.89 s of audio, plus 787 ms median formatting | `docs/superpowers/specs/2026-07-29-ara-formatting-layer-design.md:26`; `MLXFormatter` doc |
| DMG step 4: the formatting model downloads "From the menu bar, or from a terminal" | The menu never downloads. `ModelMenuModel.FormatterItem`: "The offer never fetches anything in-process… clicking it shows the exact command instead. Honest beats magic." `formatterDownloadClicked` shows an alert with a **Copy command** button | `UI/ModelMenuModel.swift:20-26`, `MenuBarController.formatterDownloadClicked` |
| "A value the file gets wrong never stops the daemon: it warns on stderr with a `config:` prefix and falls back." | Half true, and the missing half matters. Only `microphone` and `cleanup` catch their own decode errors and fall back per key. Every other key throws, and `Config.load` then **discards the whole file** — a typo in `engine` silently costs you a valid `cloud` section. `Engine.init(from:)`'s own doc comment calls this out | `Config.init(from:)`, `Config.load`, `Engine.init(from:)` |
| CLI section listed nine invocations | Eight subcommands and nine `run` flags. Missing entirely: `ara run` as an explicit form, `ara dictionary`, `ara snippets`, `--mode`, `--skip-doctor`, `--debug-hotkey`, `--dump-wav`, `--version`. Now one table each, checked line-by-line against real `--help` output | `Ara.swift`; verified by running `.build/debug/ara --help` and every subcommand |
| Parity table: "Multiple / multilingual models — 🔜 planned (translation will be free)" | Three models ship, are listed by `ara models list`, and are switchable from the **Model** submenu; `whisper-large-v3-turbo` is `languages: ["multi"]`. Split into a shipped "Multiple transcription models ✅" row and a planned "Translation 🔜" row | `ModelRegistry.shared`, `ModelMenuModel` |
| Parity table: "Per-app formatting modes ✅ (default/email/chat/code)" | Five modes. `verbatim` was omitted, and it is selectable by `--mode`, by config, and from the **Mode** submenu | `ModeRegistry.builtIns` |
| Stack: "**Swift** — single SPM executable target" | Two targets plus tests. Also omitted MLX, Core Audio, NSPasteboard and SwiftUI, all of which are load-bearing | `Package.swift` |
| Menu bar: state lines are "idle/recording/transcribing" | Five states: `warming up models…`, `idle · hold <key> to dictate`, `● recording`, `transcribing…`, `no microphone` | `MenuBarController.setWarmingUp`/`setReady`/`setRecording`/`setTranscribing`/`setNoMicrophone` |
| `ara doctor` — "check permissions, fn key, on-device formatting" | Eight checks; also the local formatting model, legacy `/tmp` logs, the installed agent's log paths, and a pre-rename LaunchAgent | `DoctorReport.run()` |

Preserved deliberately, because other files depend on them:

- The `### Unsigned builds` heading — named in prose by `scripts/package-dmg.sh:5`
  and `docs/MANUAL-VERIFICATION.md:947`.
- The dictionary example `Ara ← arra, aara` — `LocalDictionaryTests.starterMatchesREADMEExample`
  pins `LocalDictionary.starter` to it.
- The snippet trigger `insert my scheduling link` — `SnippetsTests` pins
  `Snippets.starter` to "the README's own trigger".
- The banner image, the open-model section, the fork attribution, and the
  source-install block (which was already correct).

All ten internal anchors and all cross-file links were verified to resolve by
script after the rewrite.

---

## Could not verify

- **Feature-parity columns for SuperWhisper and Wispr Flow.** Nothing in this
  repo substantiates the competitors' feature sets or prices; they are carried
  over from the previous README unchanged, with its own "judged mid-2026,
  treat as a snapshot" caveat left in place.
- **The `fn`-on-third-party-keyboards mechanism.** The code asserts the
  *outcome* ("Fn only works on Apple's built-in keyboard", `Run.hotkey` help
  text) but nothing establishes *why*. The troubleshooting entry states the
  outcome as fact, attributes it to the flag's help text, and hedges the
  firmware explanation.
- **`Ara-<version>.dmg` end-to-end.** No release is tagged, and I did not build
  or mount an image. The DMG section describes what the committed scripts do,
  which I read, not an artefact I produced.
- **Anything requiring a microphone, a keypress, or a real generation.** The
  latency and warm-up figures quoted in both documents are the ones already
  recorded in source doc comments and `MANUAL-VERIFICATION.md`; I re-measured
  none of them and cited each one's origin so a future reader can.
- **`com.cmuxterm.app`** in `ModeRegistry`'s code-mode bundle list looks like a
  typo for a terminal identifier, but I could not determine the intent, so the
  README lists only VS Code and Xcode for that row rather than guessing. Not a
  doc bug — flagged here in case it is a code one.
