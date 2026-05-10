# parrot

A minimal macOS dictation daemon. CLI-launched, push-to-talk, on-device transcription, text inserted at the cursor.

```sh
$ parrot
listening on fn hold · model: whisper-base.en · ^C to quit
```

That's it. Hold Fn, speak, release. Text appears at the cursor in whatever app is focused. A small pill at the bottom of the screen shows when the mic is hot.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup
parrot install --launch-at-login   # optional
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **FluidAudio** — Parakeet inference via CoreML (optional second engine)
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill at bottom of screen

No menubar, no dock icon, no app bundle, no settings window, no launch-at-login. If you want it always running, run it under `launchd` yourself or leave a terminal tab open.

## Usage 

```sh
parrot                              # run with defaults (fn hold, whisper-base.en)
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --model parakeet-tdt-0.6b    # pick a model
parrot --hotkey right-option        # change hotkey
parrot --no-overlay                 # disable bottom-of-screen pill
parrot models list                  # list available models
parrot models download <id>         # pre-download a model
parrot doctor                       # check permissions + Fn key setting
parrot install --launch-at-login    # register a LaunchAgent
parrot install --uninstall          # remove the LaunchAgent
```

## Status

M0 complete (skeleton builds, daemon runs, SIGINT exits cleanly). See [docs/architecture.md](docs/architecture.md) for design and [.plan/plan.md](.plan/plan.md) for milestones.

## Build

```sh
swift build
.build/debug/parrot --help
```
