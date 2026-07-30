# Microphone Robustness Design

Approved 2026-07-30.

## Problem

`AudioCapture` records from `AVAudioEngine.inputNode`, which follows the system
default input. Nothing tracks device changes. When the active input device
disappears, `inputNode.outputFormat(forBus:)` can return a 0 Hz / 0-channel
format and the next `installTap`/`start` raises an Objective-C exception Swift
cannot catch — the daemon dies. There is also no way to record from anything
but the system default.

## Decisions (user-confirmed)

- **Mid-utterance disconnect:** keep the audio captured so far, switch to the
  next available microphone, keep recording. Only the switch gap is lost.
- **Persistence:** the mic picked in the menu is written to the config file;
  on startup it is used if connected, otherwise fall back.
- **Default:** with no explicit pick, follow the system default input, tracking
  changes live.

## Architecture

**`MicrophoneStore`** (new, `Sources/AraCore/Audio/`) — single owner of "which
mics exist and which one we use." Wraps the Core Audio HAL: enumerates input
devices (ID, UID, name), listens for device-list and default-input changes,
resolves the *effective* device: config UID if connected → system default →
any available input → none. One change callback; menu and capture react to it.
The resolution rule is a pure static function, unit-testable without hardware.

**`AudioCapture`** — two changes:
1. *Never crash.* Validate the input format (channels > 0, sample rate > 0)
   before `installTap`/`start`; invalid → thrown `CaptureError`, surfaced as an
   error state, never an uncaught exception.
2. *Switch live.* Record from the store's effective device (routed explicitly
   via the input unit, not by changing the system default). While recording,
   react to engine configuration changes: tear down, re-resolve, rebuild the
   converter for the new device's native format, resume. The samples buffer
   persists across the rebuild (keep + continue). No device left → recording
   ends gracefully with what was captured.

**Menu** — `MenuBarController` gains a "Microphone" submenu: "System default" +
one radio-checked item per input device, rebuilt on store change events.
Picking persists to config (`"microphone": "<device UID>"`); System default
removes the key. The state line shows the actual device when the chosen one is
disconnected (fallback visible).

**Config** — optional `microphone: String?` (device UID). Tolerant decode as
established: garbage warns on stderr and behaves as unset. Persisting a menu
pick must not destroy unknown keys elsewhere in the file.

## Error handling

No audio path may kill the daemon. Hotkey press with no mic available → overlay
error pill + "no microphone" in the menu. Engine start failure → same.

## Testing

Pure unit tests: resolution rule, config decode/persist round-trip, menu model.
Rebuild logic behind an injectable seam with a fake device source. Real
unplug/replug is hardware-only → `docs/MANUAL-VERIFICATION.md`.

## Out of scope (YAGNI)

Per-device gain, priority ranking, output devices, level meters in the menu.
