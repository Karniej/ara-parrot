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
parrot install --purge-legacy-logs     # delete the /tmp transcript logs older versions wrote
parrot doctor                          # check permissions, fn key, on-device formatting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot --echo-transcripts              # log full transcript text (off by default)
```

### Privacy

Transcripts are never written to disk. The daemon's log lines carry timing and
a character count only (`→ 0.42s · 63 chars`); `--echo-transcripts` opts back
into the full text for interactive runs, and the LaunchAgent never uses it —
its output goes to `/dev/null`.

> If you installed parrot before this change, the background daemon was writing
> every transcript to world-readable `/tmp/parrot.{out,err}.log` — and its old
> LaunchAgent plist keeps doing so until it is rewritten. Upgrade in this order:
> re-run `parrot install --launch-at-login` first (this rewrites the agent and
> restarts the daemon), **then** `parrot install --purge-legacy-logs` to delete
> the old files. Purging first is pointless — the still-loaded old agent
> recreates them. `parrot doctor` flags both the leftover files and a stale
> plist.

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

### Snippets

Dictate a trigger phrase, get a block of text typed instead — a scheduling
link, an email sign-off, an address. Snippets live at
`~/.config/ara/snippets.json`, next to the config and dictionary, and the
file is the whole interface in v1 (no menu form — expansions are multiline,
and a single-line alert field is the wrong editor for them):

```json
[
  {
    "trigger": "insert my scheduling link",
    "expansion": "https://cal.com/pawel/30min"
  },
  {
    "trigger": "sign off formal",
    "expansion": "Best regards,\nPawel Karniej\nSilpho"
  }
]
```

A snippet fires only when the **whole utterance** is the trigger — say
*"insert my scheduling link"* and release. Matching is forgiving about how
speech gets transcribed: case does not matter, surrounding whitespace and
sentence-ending punctuation are ignored (`Insert my scheduling link.`
matches), and runs of spaces collapse. It is deliberately *not* fuzzy beyond
that: a sentence that merely *contains* the trigger ("could you insert my
scheduling link here") is formatted normally, because a snippet firing inside
a real sentence would replace words you actually wanted.

On a hit the expansion is typed **verbatim** — newlines, URLs, and exact
capitalisation survive, because no formatting engine ever sees it. One
caveat that comes with verbatim newlines: fields that treat Return as
"send" (Slack, Discord, and other chat inputs) will submit mid-expansion
at each newline, so keep snippets aimed at chat single-line. Dictionary
corrections still apply first, so a trigger word Whisper always mishears can
be fixed by a dictionary entry and the snippet still fires. The file is read
fresh on every utterance — edits apply to the next dictation, no restart —
and like the config and dictionary, a broken file never stops dictation: one
`snippets:` line on stderr, and snippets sit out until the file parses again.

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
