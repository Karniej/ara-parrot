# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions, fn key, on-device formatting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
```

### Configuration

Optional, at `~/.config/ara/config.json`. Precedence is **CLI flag > config >
default**, and every key is optional:

```json
{"hotkey": "right-command", "model": "whisper-base.en",
 "engine": "mlx", "timeoutMs": 2500, "mode": "default",
 "microphone": "AppleUSBAudioEngine:Blue:Yeti:123:1"}
```

A value the file gets wrong never stops the daemon: it warns on stderr with a
`config:` prefix and falls back. A `config:` line means part of the file did not
take effect.

### Microphone

By default parrot records from the system default input, live — change it in
System Settings and the next dictation follows. To pin a specific mic instead,
use the menu bar item → **Microphone** and pick one; the choice is saved to
the config file (the `microphone` key above — a Core Audio device UID, which
survives replug and reboot; the menu writes it so there is no reason to type
one by hand) and only that key is touched. Picking **System default** clears
it.

If the picked mic is unplugged, parrot falls back — to the system default
input, or to the first available input when the default is not usable — until
it returns; the submenu says so. A mic that dies mid-dictation does not lose
the utterance: recording continues on whatever input remains. When none does,
the pill reads "no microphone" and everything captured so far is kept —
plugging a mic in before you release the key resumes the same utterance, and
releasing transcribes what was captured up to the loss.

### Dictionary

Whisper will mishear the same words every time — your name, your product,
your city. The dictionary fixes those deterministically, before any
formatting engine runs: menu bar item → **Add dictionary correction…**, type
what dictation heard and what it should have typed, done. The very next
utterance is corrected — no restart, nothing to reload.

Corrections live at `~/.config/ara/dictionary.json`, next to the config, and
the file is meant to be hand-edited too — it is written pretty-printed with
stable ordering for exactly that reason:

```json
[
  {
    "canonical" : "Ara",
    "variants" : [
      "arra",
      "aara"
    ]
  },
  {
    "canonical" : "Kraków",
    "variants" : [
      "krakuf"
    ]
  }
]
```

Matching is case-insensitive and whole-word only (`arra` never fires inside
`arrabbiata`), and the canonical is inserted exactly as written — the
dictionary is the authority on spelling, capitalisation included. The file is
read fresh on every utterance, so a hand edit applies to the next dictation
the same way a menu addition does. And like the config, a broken file never
stops dictation: one `dictionary:` line on stderr, and corrections sit out
until the file parses again.

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
scripts/build-metallib.sh    # compile the Metal kernels SwiftPM can't (needs Xcode)
.build/release/parrot --help
```

The second step exists because the default formatting engine runs a bundled
language model on MLX, and SwiftPM cannot compile MLX's Metal shaders — a
plain `swift build` binary starts fine but formats with rule-based cleanup
only, and `parrot doctor` will say so. The script compiles the kernel library
once through `xcodebuild` and drops `mlx.metallib` next to the binary. The
model itself is a separate one-time download:
`parrot models download-formatter` (~900 MB).
