<p align="center">
  <img src="docs/assets/ara.png" alt="Ara — free, open, on-device dictation" width="720">
</p>

# Ara

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

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on
the Apple Neural Engine via CoreML, so Intel is not supported.

Ara is source-only today — no tagged release has shipped yet, so there is
nothing for a download to fetch. Building takes one command plus a Metal step:

```sh
git clone https://github.com/Karniej/ara-parrot.git && cd ara-parrot
swift build -c release
scripts/build-metallib.sh                     # compiles the Metal kernels SwiftPM cannot
./.build/release/ara models download-formatter  # the local formatting model, ~900 MB, once
./.build/release/ara setup                    # microphone + accessibility permissions
./.build/release/ara                          # run it
```

Put it on your `PATH` if you want `ara` from anywhere:

```sh
ln -sf "$PWD/.build/release/ara" ~/.local/bin/ara
```

Then `ara install --launch-at-login` registers the background daemon, which is
the recommended way to run it: models warm once at login instead of on every
launch. See [Build from source](#build-from-source) for what each step does.

When a tagged release ships, `scripts/install.sh` becomes the one-line path
(`curl -fsSL .../install.sh | sh`, dropping the binary in `/usr/local/bin/ara`).
Builds will be unsigned at first, so macOS will ask you to confirm the first run.

### Upgrading from `parrot`

This tool used to be called `parrot`. The binary is now `ara`, and that is the
only thing that moves.

**The background daemon.** The LaunchAgent's label changed too
(`com.digimata.parrot` → `com.silpho.ara`), and launchd sees no connection
between the two — left alone, the old agent goes on starting the old binary at
every login, so enabling Start at Login would leave two daemons fighting over
the hotkey. You do not have to clean that up by hand: both
`ara install --launch-at-login` and `ara install --uninstall` boot the old
agent out and delete its plist, printing the path they removed. `ara doctor`
warns while one is still there.

**A symlink on your `PATH`.** If you had `~/.local/bin/parrot` pointing at a
build directory, repoint it — the built binary has a new name:

```sh
ln -sf "$(pwd)/.build/release/ara" ~/.local/bin/ara && rm -f ~/.local/bin/parrot
```

**Your settings.** Nothing to do. The config directory has been `~/.config/ara/`
since before the rename, so `config.json`, `dictionary.json` and
`snippets.json` are already where the new binary looks — same paths, same
contents, no migration step.

**The old transcript logs.** `/tmp/parrot.out.log` and `/tmp/parrot.err.log`
keep those names forever: they are files already on your disk, not branding, so
that is what `ara install --purge-legacy-logs` still looks for. See
[Privacy](#privacy) for the order to run things in.

## How to use

1. **Run it.** Either `ara install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `ara` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `ara setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
ara                                 # run in the foreground (^C to quit)
ara setup                           # one-time setup: permissions + model download
ara install --launch-at-login       # register a LaunchAgent (background daemon)
ara install --uninstall             # remove the LaunchAgent
ara install --purge-legacy-logs     # delete the /tmp transcript logs older versions wrote
ara doctor                          # check permissions, fn key, on-device formatting
ara models list                     # list available models
ara models download <id>            # pre-download a model
ara --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
ara --hotkey right-option           # change the push-to-talk key
ara --inject type                   # force typing (or: paste); default is auto
ara --no-overlay                    # disable the bottom-of-screen pill
ara --echo-transcripts              # log full transcript text (off by default)
```

### Privacy

Transcripts are never written to disk. The daemon's log lines carry timing and
a character count only (`→ 0.42s · 63 chars`); `--echo-transcripts` opts back
into the full text for interactive runs, and the LaunchAgent never uses it —
its output goes to `/dev/null`.

> If you installed this tool before this change — under its old name, `parrot` —
> the background daemon was writing every transcript to world-readable
> `/tmp/parrot.{out,err}.log`, and its old LaunchAgent plist keeps doing so until
> it is rewritten. Those filenames are what is on your disk, so they are what the
> cleanup still looks for. Upgrade in this order: re-run
> `ara install --launch-at-login` first (this rewrites the agent and restarts the
> daemon), **then** `ara install --purge-legacy-logs` to delete the old files.
> Purging first is pointless — the still-loaded old agent recreates them.
> `ara doctor` flags both the leftover files and a stale plist.

### The menu bar

The bird in the menu bar is the daemon's whole control surface — every CLI
and config capability has a door here. Three disabled lines up top tell you
what the daemon is doing (idle/recording/transcribing, the model it runs,
and the mode the last utterance resolved). Below them, what each item does
and — the part worth reading — *when* it takes effect:

| Item | What it does | Applies |
|---|---|---|
| **Microphone** | pick an input device (or System default); saved to `microphone` | next utterance |
| **Cleanup** | editing intensity none→high; saved to `cleanup` | on restart |
| **Mode** | pin a mode, or **Auto (per app)**; deliberately *never* saved — it is a session override, and the `mode` key stays your startup default | next utterance |
| **Model** | pick a transcription model; saved to `model`; a model not on disk is downloaded by the next launch | on restart |
| **Model → formatting model line** | says "✓ downloaded", or offers the `ara models download-formatter` command with a copy button — the 900 MB fetch stays an explicit CLI action | on restart |
| **Hotkey** | pick the push-to-talk key; saved to `hotkey` | on restart |
| **Engine** | mlx / apple / cloud / rules / off; saved to `engine`; the cloud row reads "(no API key set)" when the daemon started without one | on restart |
| **Add dictionary correction…** / **Edit dictionary…** / **Edit snippets…** | the vocabulary doors — see their sections below | next utterance |
| **Start at Login** | installs or removes the LaunchAgent; the checkmark is the plist on disk. Enabling *starts the login copy immediately* — quit a terminal-run daemon after enabling, or two daemons answer the hotkey | immediately |
| **Run Diagnostics…** | `ara doctor`'s report in a window, monospaced, with a Copy report button | — |
| **Quit Ara** | quits | immediately |

Every submenu whose pick is not immediate states its timing in a caption, so
the menu never claims a restart-bound pick changed the running session; the
Microphone and Mode submenus need none, because they apply at once. A pick that could not be
saved (an unwritable or malformed config file) keeps the old checkmark and
warns on stderr — the file is never overwritten with a guess.

### Configuration

Optional, at `~/.config/ara/config.json`. Precedence is **CLI flag > config >
default**, and every key is optional:

```json
{"hotkey": "right-command", "model": "whisper-base.en",
 "engine": "mlx", "timeoutMs": 2500, "mode": "default",
 "inject": "auto", "pasteRestoreMs": 300,
 "cleanup": "medium",
 "microphone": "AppleUSBAudioEngine:Blue:Yeti:123:1"}
```

A value the file gets wrong never stops the daemon: it warns on stderr with a
`config:` prefix and falls back. A `config:` line means part of the file did not
take effect.

### Injection: typing vs paste

Ara has two ways to deliver a transcript, controlled by the `inject` key
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
- Anything **you** copy during the restore window wins: the restore checks
  the pasteboard's change count and stands down rather than overwrite a ⌘C
  you just made in another app.
- `pasteRestoreMs` (default 300, clamped to 50–5000) is how long the target
  app gets to service the ⌘V before the snapshot is restored. Too low and a
  slow app pastes your *old* pasteboard instead of the transcript; higher
  values just mean the transcript sits on the pasteboard longer after each
  dictation (a ⌘V of your own in that window pastes the transcript). Raise
  it if a laggy app (remote desktop, a busy Electron app) pastes stale
  content.
- If the pasteboard write or the ⌘V synthesis fails, the transcript is
  delivered through the typing path instead — it is never lost.
`cleanup` sets how aggressively dictation is edited, independently of the
mode: `"none"` skips the language model entirely (filler stripping only),
`"light"` adds punctuation and capitalisation but keeps every spoken word,
`"medium"` (the default) also removes fillers, collapses spoken
self-corrections ("we ship Tuesday, no wait, Wednesday" → "We ship
Wednesday.") and obeys dictated punctuation ("comma", "period", "question
mark"), and `"high"` additionally restructures fragments into complete
sentences and formats spoken enumerations ("number one… number two…") as
numbered lists. Dictated "new line"/"new paragraph" currently become a
sentence break, not a real line break — a measured limit of the local model,
recorded in docs/KNOWN-ISSUES.md.

The menu bar's **Cleanup** submenu shows the four intensities with a check on
the active one and writes a pick back to the config — but unlike everything
else in the menu it takes effect on the next launch, not the next utterance
(the intensity is baked into the session at startup), and the submenu says so.

### Microphone

By default Ara records from the system default input, live — change it in
System Settings and the next dictation follows. To pin a specific mic instead,
use the menu bar item → **Microphone** and pick one; the choice is saved to
the config file (the `microphone` key above — a Core Audio device UID, which
survives replug and reboot; the menu writes it so there is no reason to type
one by hand) and only that key is touched. Picking **System default** clears
it.

If the picked mic is unplugged, Ara falls back — to the system default
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

**Edit dictionary…**, right below the correction form in the menu, opens the
file in whatever edits JSON on your Mac — writing it first with the example
entry above if it does not exist yet, so the format explains itself. To see
what is there without opening anything, `ara dictionary` prints the path
and every correction.

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

**Edit snippets…** in the menu bar opens the file in your default editor —
writing it first with a one-entry example if it does not exist yet — and
`ara snippets` prints the path and every trigger without opening anything.

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
| Cleanup intensity dial (none→high) | ❌ | ✅ | ✅ `cleanup` config key + menu |
| Reliable delivery into terminals/Electron | ✅ option | ✅ | ✅ auto per-app paste |
| Transcripts kept out of world-readable logs | ❌ audio kept forever | cloud-side | ✅ length-only logs by default |
| Per-app formatting modes | ✅ | ✅ | ✅ (default/email/chat/code) |
| Custom dictionary / replacements | ✅ | ✅ | ✅ hot-reloaded JSON + menu |
| Survives mic unplug mid-dictation | ❌ | partial | ✅ **keeps the utterance** |
| Microphone picker | ✅ | ✅ auto | ✅ menu, persisted |
| Auto-learning dictionary (correct once, remembered) | ❌ | ✅ | 🔜 planned, local-only |
| History + search + reprocess | ✅ | partial | 🔜 planned, with retention controls |
| Context awareness (selected text → cleanup) | ✅ | ✅ (cloud, incl. screenshots) | 🔜 planned, local-only |
| Voice commands on selection ("make this shorter") | ❌ | ✅ paid | 🔜 planned |
| Snippets (voice text expansion) | ❌ | ✅ | ✅ `snippets.json`, hot-reloaded |
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
.build/release/ara --help
```

The second step exists because the default formatting engine runs a bundled
language model on MLX, and SwiftPM cannot compile MLX's Metal shaders — a
plain `swift build` binary starts fine but formats with rule-based cleanup
only, and `ara doctor` will say so. The script compiles the kernel library
once through `xcodebuild` and drops `mlx.metallib` next to the binary. The
model itself is a separate one-time download:
`ara models download-formatter` (~900 MB).
