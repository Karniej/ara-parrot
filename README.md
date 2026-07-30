# Ara (parrot)

A free macOS dictation daemon. Push-to-talk, on-device transcription, AI
cleanup on an open model, text inserted at the cursor. A fork of
[digimata/parrot](https://github.com/digimata/parrot), building toward
[feature parity](#feature-parity) with the paid dictation apps — while
staying free, local, and open.

## The open-model approach

Everything that touches your voice runs on your machine, on open-weights
models, at no cost:

- **Transcription** is Whisper (OpenAI's open speech model) running on the
  Apple Neural Engine via WhisperKit. No audio leaves the Mac.
- **Cleanup** — filler removal, punctuation, capitalisation, per-app tone —
  is Qwen 2.5 (Alibaba's open 1.5B model, Apache-licensed) running locally
  on MLX, Apple's ML framework. Measured on an M3 Pro it formats a sentence
  in ~400 ms, well under the app's 2.5 s budget. No API key, no account, no
  subscription, no server.
- **Corrections** — the custom dictionary — are a deterministic pass over
  the transcript, applied before any model sees it. Plain JSON on disk,
  yours to edit.
- **Fallbacks never lose your words.** If a model is missing, slow, or
  wrong, the transcript falls through to rule-based cleanup and is typed
  anyway. The language model is polish, not a dependency.

Cloud engines exist as an *opt-in* (`engine: "cloud"` with your own key) and
Apple Intelligence as another (`engine: "apple"`); the default install makes
zero network requests for formatting. The paid competition inverts this:
Wispr Flow sends every dictation — with surrounding screen context — to
their servers, and SuperWhisper gates its larger models and translation
behind a subscription. Ara's bet is that open models on Apple Silicon are
already good enough that dictation software has no business charging rent
or reading your screen.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

> **Fork note:** the curl installer above ships the *upstream* parrot binary.
> Ara's additions — the local formatting engine, dictionary, microphone
> picker — are currently source-only: use [Build from
> source](#build-from-source) below. A signed Ara release pipeline is on the
> roadmap.

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
parrot --inject type                   # force typing (or: paste); default is auto
parrot --no-overlay                    # disable the bottom-of-screen pill
```

### Configuration

Optional, at `~/.config/ara/config.json`. Precedence is **CLI flag > config >
default**, and every key is optional:

```json
{"hotkey": "right-command", "model": "whisper-base.en",
 "engine": "mlx", "timeoutMs": 2500, "mode": "default",
 "inject": "auto", "pasteRestoreMs": 300,
 "microphone": "AppleUSBAudioEngine:Blue:Yeti:123:1"}
```

A value the file gets wrong never stops the daemon: it warns on stderr with a
`config:` prefix and falls back. A `config:` line means part of the file did not
take effect.

### Injection: typing vs paste

Parrot has two ways to deliver a transcript, controlled by the `inject` key
(or `--inject`):

- **`type`** synthesizes the characters as keyboard events. It leaves your
  pasteboard alone, but terminals and Electron apps (VS Code, Slack, Discord…)
  drop or mangle synthesized unicode typing — the platform API reports success
  either way, so the failure is silently missing characters.
- **`paste`** snapshots your pasteboard, puts the transcript on it, sends ⌘V,
  and restores the snapshot a moment later. This is what every serious
  dictation tool does in those apps, because paste is the one path they all
  handle correctly.
- **`auto`** (the default) pastes into a built-in list of terminals and
  Electron apps — Terminal, iTerm2, VS Code, Cursor, Slack, Discord, kitty,
  Alacritty, WezTerm — and types everywhere else.

The paste path is careful with your pasteboard:

- The snapshot keeps **every representation of every item**, so a copied
  image or file survives the round trip intact.
- The transcript is marked `org.nspasteboard.TransientType`, so clipboard
  managers that honour the convention will not record it.
- Items marked `org.nspasteboard.ConcealedType` — password-manager copies —
  are deliberately **not restored**. They are ephemeral by their producer's
  design; putting a password back on the pasteboard after its manager retired
  it would be a leak. Copy the password again if you need it after dictating.
- `pasteRestoreMs` (default 300, clamped to 50–5000) is how long the target
  app gets to service the ⌘V before the snapshot is restored. Too low and a
  slow app pastes your *old* pasteboard instead of the transcript; higher
  values just mean the transcript sits on the pasteboard longer after each
  dictation. Raise it if a laggy app (remote desktop, a busy Electron app)
  pastes stale content.
- If the pasteboard write or the ⌘V synthesis fails, the transcript is
  delivered through the typing path instead — it is never lost.

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

## Feature parity

Where Ara stands against the two best-known paid dictation apps,
[SuperWhisper](https://superwhisper.com) ($8.49/mo or $249 lifetime) and
[Wispr Flow](https://wisprflow.ai) ($15/mo, cloud-only). Judged mid-2026;
both move fast, so treat the paid columns as a snapshot.

| Feature | SuperWhisper | Wispr Flow | Ara |
|---|---|---|---|
| Works fully offline | ✅ | ❌ never | ✅ **always, by default** |
| Price | Free tier + paid | Free tier + paid | **Free, MIT, forever** |
| Push-to-talk on a modifier key | ✅ | ✅ | ✅ |
| AI cleanup (fillers, punctuation, caps) | ✅ paid models | ✅ cloud | ✅ local open model |
| Per-app formatting modes | ✅ | ✅ | ✅ (default/email/chat/code) |
| Custom dictionary / replacements | ✅ | ✅ | ✅ hot-reloaded JSON + menu |
| Survives mic unplug mid-dictation | ❌ | partial | ✅ **keeps the utterance** |
| Microphone picker | ✅ | ✅ auto | ✅ menu, persisted |
| Auto-learning dictionary (correct once, remembered) | ❌ | ✅ | 🔜 planned, local-only |
| History + search + reprocess | ✅ | partial | 🔜 planned, with retention controls |
| Context awareness (selected text → cleanup) | ✅ | ✅ (cloud, incl. screenshots) | 🔜 planned, local-only |
| Voice commands on selection ("make this shorter") | ❌ | ✅ paid | 🔜 planned |
| Snippets (voice text expansion) | ❌ | ✅ | 🔜 planned |
| Hands-free / locked dictation | ✅ | ✅ | 🔜 planned |
| Multiple / multilingual models | ✅ paid | ✅ | 🔜 planned (translation will be free) |
| Streaming preview while speaking | ✅ | ✅ | not yet |
| Meeting recording + speaker separation | ✅ | ❌ | not planned |
| iPhone | ✅ | ✅ | someday |
| Sends your screen contents to a server | no | **yes, unless Privacy Mode** | **never — there is no server** |

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
