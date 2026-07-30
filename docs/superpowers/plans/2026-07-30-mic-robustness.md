# Microphone Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** parrot survives microphone disconnects (keeps the utterance, switches to the next available input, never crashes) and gains a Microphone submenu in the status-bar menu with a persisted choice.

**Architecture:** A new `MicrophoneStore` owns device enumeration, change listening, and effective-device resolution. `AudioCapture` records from the store's effective device, validates formats before touching AVFoundation, and rebuilds mid-recording on device loss while keeping accumulated samples. `MenuBarController` renders the store's state and writes the pick to config.

**Tech Stack:** Swift 6.3, SwiftPM, swift-testing, Core Audio HAL (CoreAudio framework), AVAudioEngine. Spec: `docs/superpowers/specs/2026-07-30-mic-robustness-design.md`.

## A note on how this plan is written

Like the MLX plan before it, this plan specifies **contracts and constraints, not API call shapes**. Core Audio property-listener code written from memory is exactly the kind of plausible-looking code that reviews caught ten defects in last time. Derive the call shapes from the SDK headers and the compiler. Where this plan states a mechanism (a property selector, a notification name), treat it as a strong hint verified against documentation intent, not as gospel.

## Global Constraints

- **No audio path may kill the daemon.** AVFoundation raises Objective-C exceptions Swift cannot catch when given a dead device (`installTap` with a 0-channel/0 Hz format). Every such call must be preceded by a validation that makes the exception unreachable, and every failure becomes a thrown Swift error surfaced as UI state.
- **Never lose captured audio.** A mid-recording device loss keeps the samples accumulated so far; the utterance continues on the next device or ends gracefully with what exists. `stop()` always returns whatever was captured.
- **parrot never changes the system default input.** Device routing is per-engine (the input unit's current-device property), invisible to other apps.
- **Event-driven, no polling.** Device-list and default-input changes arrive via Core Audio property listeners; mid-recording engine death arrives via `AVAudioEngine` configuration-change notification.
- **All UI mutation on `@MainActor`.** Core Audio listeners fire on arbitrary threads; hop before touching menu state.
- **Tolerant config, established pattern.** New optional `microphone` (device UID string). Unknown/garbage values warn on stderr and behave as unset. Persisting a pick must not destroy other keys in the file, including keys this version of parrot does not know about.
- **Package platform stays `.macOS(.v14)`.** `public` means "the executable consumes it".
- Existing behavior when nothing changes: with no config key and no menu pick, recording follows the system default input, live — identical to today from the user's view, minus the crash.

---

### Task 1: `MicrophoneStore` + crash-proof, device-routed `AudioCapture`

**Files:**
- Create: `Sources/AraCore/Audio/MicrophoneStore.swift`
- Modify: `Sources/AraCore/Audio/AudioCapture.swift`, `Sources/AraCore/Config/Config.swift`
- Test: `Tests/AraCoreTests/MicrophoneStoreTests.swift`, `Tests/AraCoreTests/AudioCaptureTests.swift`

**Interfaces produced (later tasks rely on):**
- `MicrophoneStore` exposing: `struct Device { id: AudioDeviceID; uid: String; name: String }`, a read of the current device list, a read of the effective device (and whether it is a fallback from a disconnected preference), `setPreferredUID(String?)`, and a single `onChange` callback fired on any list/default/effective change.
- `AudioCapture.start(device:)` (or equivalent store-driven form) plus an injectable seam for tests.
- `Config.microphone: String?`.

**Contract, not code:**

1. **Resolution is pure.** `resolve(preferredUID:devices:systemDefaultID:) -> Effective` is a static function with no Core Audio dependency: preferred UID if present in `devices` → system default if present → first available input → none. It reports *why* (chosen / fallback / default / none) so the menu can label state honestly. Exhaustively unit-tested including: preferred connected, preferred missing, no default, empty list.
2. **Enumeration lists input devices only** (devices with input streams), with UID and human name. Aggregate/virtual devices appear as themselves; no filtering cleverness.
3. **Listeners:** device-list changes and default-input changes each trigger re-resolution; `onChange` fires only when the resolved result or list actually changed. Listener registration has a matching removal (deinit or explicit stop) — no dangling blocks.
4. **`AudioCapture` validates before it touches AVFoundation.** Channels > 0 and sample rate > 0 on the input format, else throw a new `CaptureError` case. This check is the crash fix; a test must prove the guard exists at the call site (injectable format probe or equivalent seam — a mutation deleting the guard must fail a test).
5. **Explicit routing.** When the effective device is not "whatever the engine does by default", set the input unit's current device before start. Routing failure → thrown error, not a crash.
6. **Mid-recording rebuild.** While recording, an engine configuration-change notification triggers: tear down tap+engine, re-resolve via the store, rebuild converter for the new device's native format, resume recording into the SAME samples buffer. No device → stop accumulating, remain in a state where `stop()` returns the captured samples. The rebuild decision logic must be testable without hardware (seam: the notification handler calls an internal `handleConfigurationChange()` whose collaborators are injectable).
7. **Thread-safety:** the samples buffer is already lock-protected; the rebuild path must hold the same discipline. Listener callbacks and the audio tap run on arbitrary threads.

- [ ] **Step 1: Write the failing tests** for the resolution rule (all branches), config decode of `microphone` (present, absent, wrong type — file must not be discarded), the format-validation guard, and the rebuild decision (device lost → re-resolve → resume; no device → graceful degrade, samples retained).
- [ ] **Step 2: Run them, confirm they fail.**
- [ ] **Step 3: Implement `MicrophoneStore`.**
- [ ] **Step 4: Implement the `AudioCapture` changes.**
- [ ] **Step 5: Run the whole suite** (`swift test`) — all pre-existing tests must still pass; `AudioCapture`'s existing callers must compile unchanged or be updated in this task.
- [ ] **Step 6: Commit.**

---

### Task 2: Microphone submenu, config persistence, daemon wiring

**Files:**
- Modify: `Sources/AraCore/UI/MenuBarController.swift`, `Sources/parrot/Parrot.swift`, `Sources/AraCore/Config/Config.swift` (persist helper if none fits elsewhere), `docs/MANUAL-VERIFICATION.md`, `README.md`
- Test: `Tests/AraCoreTests/MenuMicrophoneTests.swift`, extend `Tests/AraCoreTests/ConfigTests.swift`

**Interfaces consumed:** everything Task 1 produced.

**Contract, not code:**

1. **Submenu.** "Microphone" submenu in the existing menu: first item "System default", then one item per device from the store, radio-style check on the active selection ("System default" checked when no preference is set). Rebuilt on `onChange`. A state line shows the *effective* device when it differs from the preference (fallback visible), and "no microphone" when none.
2. **Selection flow.** Menu pick → `store.setPreferredUID` → persist to config file. "System default" → `setPreferredUID(nil)` → remove the key. Persistence rewrites only that key: read the existing file as generic JSON, set/remove `microphone`, write back — unknown keys survive byte-for-byte where JSON allows. Round-trip tested against a config containing keys the codebase does not define.
3. **Wiring in `Run`.** Store created at startup with the config's `microphone`; capture consumes the store; menu consumes the store; a device change while idle re-arms nothing (next utterance picks it up via resolution); no mic at hotkey-press → the existing error surface (overlay + menu state), daemon alive.
4. **Menu logic testable off-screen.** The submenu's item model (titles, checkmarks, enabled state) is computed by a pure function from store state — unit-tested; `NSMenu` rendering stays a thin shell.
5. **Docs.** `docs/MANUAL-VERIFICATION.md` gains the hardware checks: unplug USB mic mid-dictation (utterance survives on fallback device), unplug with no other mic (utterance ends with captured audio, daemon alive), AirPods connect/disconnect, menu pick persists across restart. README documents the config key and the menu.

- [ ] **Step 1: Write the failing tests** — menu item model (device list + preference → titles/checks; fallback labeling; none case), config persist round-trip preserving unknown keys.
- [ ] **Step 2: Run them, confirm they fail.**
- [ ] **Step 3: Implement menu + persistence.**
- [ ] **Step 4: Wire `Run`.**
- [ ] **Step 5: Full suite + release build.**
- [ ] **Step 6: Commit**, including the docs.

## Self-Review

**Coverage:** crash fix (Task 1 contract 4), keep+continue (contract 6), menu picker (Task 2 contracts 1–2), persistence (Task 2 contract 2), follow-system-default (contract 1 resolution order), no-mic degradation (contracts 6/Task 2 contract 3) — all four user decisions map to contracts.

**Known risk:** the exact Core Audio surface (property selectors, listener registration) is intent, not verified code — Task 1's implementer derives it from headers and must report what it found. Hardware disconnect cannot run in CI; the rebuild *decision* is unit-tested, the physical event is MANUAL-VERIFICATION.

**Deliberately not in scope:** per-device gain, priority ranking, output devices, level meters.
