# Parrot — Implementation Plan

A minimal macOS dictation daemon. CLI-launched, push-to-talk on Fn hold, on-device transcription via WhisperKit/Parakeet, text injected at cursor.

See [../docs/architecture.md](../docs/architecture.md) for the full design.

## Approach

Phased, each milestone produces something testable end-to-end. Linear order — each phase de-risks the next. M4 (WhisperKit transcription) is the load-bearing de-risk: if ANE latency is insufficient there, the rest of the plan is moot.

## Milestones

### M0 — Project skeleton

Goal: builds, runs, exits cleanly. No behavior.

- `Package.swift` — SPM exec target, `swift-argument-parser` dep
- `Sources/parrot/main.swift` — argument parsing, `setActivationPolicy(.accessory)`, `NSApp.run()`, SIGINT handler
- Empty subfolder stubs (`Audio/`, `Input/`, `Transcription/`, `Models/`, `UI/`)

**Test:** `swift run parrot` starts and stops cleanly. `parrot --help` works. No dock icon, no menubar.

### M1 — Doctor + permissions surface

Goal: actionable feedback on permission state before anything tries to use the perms.

- `Doctor.swift` — checks: microphone (`AVCaptureDevice.authorizationStatus`), accessibility (`AXIsProcessTrusted`), Fn-key system mapping
- `parrot doctor` subcommand prints status + remediation steps

**Test:** Run before granting perms — see red Xs and instructions. Grant perms, re-run — see green checks.

### M2 — Hotkey monitor (Fn hold)

Goal: clean `.pressed` / `.released` events for Fn.

- `HotkeyMonitor.swift` — `CGEventTap` on `flagsChanged`, detect `kCGEventFlagMaskSecondaryFn` edges
- Wire into `main.swift` — log "fn down" / "fn up" to stderr

**Test:** Hold Fn, see "fn down". Release, see "fn up". No double-fires; no missed releases when switching apps mid-hold.

### M3 — Audio capture

Goal: clean PCM buffer for the duration of the hold.

- `AudioCapture.swift` — `AVAudioEngine` input tap, 16 kHz mono Float32, ring buffer
- Start on `.pressed`, stop on `.released`, log buffer length + RMS to stderr
- (Optional) write captured PCM to `/tmp/parrot-last.wav` for QuickTime inspection

**Test:** Hold Fn, talk, release. stderr shows `captured 3.2s, RMS 0.08`. WAV plays back as clean speech.

### M4 — WhisperKit transcription (de-risk milestone)

Goal: end-to-end audio → text in the terminal. Validates that ANE latency hits target.

- Add WhisperKit dep
- `TranscriptionModel.swift` + `ModelRegistry.swift` + `Resources/models.json` (3 entries)
- `ModelDownloader.swift` with stderr progress
- `Transcriber.swift` protocol + `WhisperKitTranscriber.swift`
- `parrot models list` and `parrot models download <id>`
- Wire end-to-end: `.released` → transcribe → log to stderr

**Test:** `parrot models download whisper-base.en`. Hold Fn, say "hello world", release — transcript on stderr. Measure latency for 5s and 10s utterances. Target: <500ms post-release for <10s clips.

### M5 — Text injection

Goal: the actual product loop.

- `TextInjector.swift` — `CGEvent` + `CGEventKeyboardSetUnicodeString`
- Replace stderr log with cursor injection

**Test:** TextEdit, Slack, Safari address bar, VS Code, fish prompt — text appears at cursor in each.

### M6 — Recording overlay

Goal: visual feedback that mic is hot.

- `RecordingOverlay.swift` — borderless `NSWindow`, `.statusBar` level, `ignoresMouseEvents`, `NSHostingView` + SwiftUI pill (pulsing dot + "listening")
- States: hidden → recording → transcribing → hidden, driven by hotkey + transcription lifecycle
- (Optional) mic-level animation from `AudioCapture`

**Test:** Pill appears bottom-center on Fn down, animates, switches to spinner on release, disappears after injection. Clicks pass through to the app underneath.

### M7 — Parakeet engine + Config TOML

Goal: second engine, persistent config.

- `ParakeetTranscriber.swift` (FluidAudio)
- Add `parakeet-tdt-0.6b-v3` to registry
- `Config.swift` — TOML loader at `~/.config/parrot/config.toml`, CLI flags override
- `--model`, `--hotkey`, `--no-overlay` flags

**Test:** Switch engines via flag and config; both produce reasonable transcripts. Benchmark latency on identical 5s clip.

### M8 — Polish

Goal: shippable to a second user.

- Resumable downloads, size validation
- Error UX: missing model, perm denied, tap registration failure
- Release build, install instructions in README
- Decide: code signing for stable accessibility grant

**Test:** Fresh-clone simulation — clone, build, doctor, download, dictate. Time-to-first-transcript < 5 minutes.

## Commit boundaries

One milestone ≈ one commit (or a small linear series). Don't fold M5 into M4 — keeping the audio→text loop separate from injection makes regressions bisectable.

## Open questions (deferred)

- Parakeet via FluidAudio vs. direct CoreML — decide at M7 after benchmarking
- Bundle `whisper-base.en` for first-run UX, or always download — decide at M8
- Code signing for stable TCC grants — decide at M8
