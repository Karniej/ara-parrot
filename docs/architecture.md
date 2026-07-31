# Architecture

A contributor's map of Ara: the two targets, the path a spoken sentence takes
from the hotkey to the cursor, the seams that make that path testable, and the
constraints that shaped it. Everything here is checkable against the source;
where a decision has a measured number behind it, the number and where it was
measured are named.

## The two targets

`Package.swift` declares three targets, of which two ship:

| Target | Kind | Contains |
|---|---|---|
| `AraCore` | library | everything: audio, hotkey, transcription, formatting, vocabulary, config, menu bar, install, doctor |
| `ara` | executable | `Sources/ara/Ara.swift` — argument parsing, and the wiring that assembles the daemon |
| `AraCoreTests` | test | `Tests/AraCoreTests/`, 33 files |

The split is not organisational tidiness. `Run.run()` cannot be called from a
test — it registers an event tap, takes over the run loop, and never returns —
so every decision with rules in it was moved out of the executable and into the
library, where a test can reach it. What is left in `Ara.swift` is the keychain
read, one `process` call, one injection, and the callbacks that connect menu
picks to library functions. `Pipeline` and `StartupResolution` exist for
exactly this reason, and both say so in their doc comments: a helper that works
while nothing proves production uses it is a failure this project has already
shipped once.

The library is the only place with dependencies (WhisperKit, MLX,
swift-transformers, ArgumentParser); the executable depends on `AraCore` and
ArgumentParser.

The model registry lives in Swift source (`ModelRegistry.shared`), not in a
JSON resource, so the executable is genuinely a single binary with no resource
bundle to install beside it. The menu bar's bird icon is an inlined SVG string
in `MenuBarController` for the same reason.

## The dictation path, end to end

```
                                    ┌─────────────────────┐
                                    │  Sources/ara        │
                                    │  Ara.swift (Run)    │
                                    └──────────┬──────────┘
                                               │ wires, then NSApp.run()
        ┌──────────────────┐                   ▼
        │  HotkeyMonitor   │ .pressed ┌─────────────────────┐   ┌────────────────┐
        │  (CGEventTap)    │─────────▶│   AudioCapture      │◀──│ MicrophoneStore│
        │       ▲          │ .released│   (AVAudioEngine)   │   │  (Core Audio)  │
        │  ModifierEdge    │─────────▶└──────────┬──────────┘   └────────────────┘
        │    Detector      │                     │ [Float] 16 kHz mono
        └──────────────────┘                     ▼
                                    ┌─────────────────────┐
                                    │ WhisperKitTranscriber│  CoreML / ANE
                                    │ + dictionary hints  │  ← per-utterance file read
                                    └──────────┬──────────┘
                                               │ String
        FrontmostApp.bundleID ────────────────▶│  (sampled at release, by value)
        ManualMode.id        ────────────────▶│
                                               ▼
                                    ┌─────────────────────┐
                                    │  DictationSession   │  actor
                                    │  1. LocalDictionary │  ← per-utterance file read
                                    │  2. Snippets ───────┼──▶ hit: expansion, verbatim,
                                    │  3. ModeResolver    │     bypassing everything below
                                    │  4. applying(cleanup)│
                                    └──────────┬──────────┘
                                               ▼
                                    ┌─────────────────────┐
                                    │   FormatterChain    │  per-formatter deadline
                                    │  mlx → rules        │  + OutputGuard per candidate
                                    │  apple → rules      │
                                    │  cloud → mlx → rules│
                                    └──────────┬──────────┘
                                               │ String, never throws (except cancellation)
                                               ▼
                                    ┌─────────────────────┐
                                    │  InjectionPolicy    │  auto / type / paste
                                    │   ├ TextInjector    │  CGEvent unicode
                                    │   └ PasteInjector   │  snapshot / ⌘V / restore
                                    └─────────────────────┘
```

Step by step, with what each stage guarantees:

1. **Hotkey.** `HotkeyMonitor` installs a listen-only `CGEventTap` at
   `.cgSessionEventTap`, subscribed to `flagsChanged` **only** — deliberately
   narrowed, because subscribing to keyDown/keyUp would hand this process the
   keycode of every keystroke typed system-wide. The tap callback copies the
   event and hops to the main queue; the press/release decision itself lives in
   `ModifierEdgeDetector`, which is pure and unit-tested.

2. **Capture.** `.pressed` starts `AudioCapture`, which routes its own
   `AVAudioEngine` to the device `MicrophoneStore` resolved, taps the input
   node, and converts to 16 kHz mono `Float32` inside the tap callback. The
   system default input is never written.

3. **Release, and the by-value sample.** On `.released` the samples are taken,
   and — on the main actor, where the AppKit read is legal — `FrontmostApp.bundleID`
   and the menu's `ManualMode.id` are sampled and **carried by value into that
   utterance's task**. `FrontmostApp`'s doc comment carries the argument: an
   earlier version cached the answer in a shared slot read at format time, and
   because formatting happens seconds after release, a user who started a
   second utterance before the first came back got the first one formatted in
   the second's mode — speech dictated into Mail arriving as a code-mode
   rewrite. A value sampled at release cannot be overwritten by a later
   utterance, which makes the property structural rather than a matter of
   timing.

4. **Transcribe.** `WhisperKitTranscriber` (an actor) snapshots the dictionary's
   canonical spellings, tokenizes them into a bounded decoder prompt, runs
   CoreML inference on the ANE, and sanitizes Whisper's non-speech bracket
   tokens (`[BLANK_AUDIO]`, `(silence)`, `<|nospeech|>`, `*background noise*`).
   Every language-refinement pass for the utterance receives the same prompt;
   an empty dictionary passes `nil` and keeps WhisperKit's baseline path.

5. **Dictionary.** `DictationSession.process` applies `LocalDictionary` first,
   before any mode or engine decision, so every path — including verbatim and
   `engine: off` — sees the corrected words and no language model can
   paraphrase a term it only ever saw misheard.

6. **Snippets.** If the whole corrected utterance normalizes to a trigger, the
   expansion is returned as the final output: no mode, no chain, no output
   guard. That bypass is what lets an expansion carry newlines and exact
   capitalisation to the injector untouched.

7. **Mode resolution.** `ModeResolver.resolve` — precedence `--mode` flag >
   menu pick > frontmost app > `config.mode` > built-in default — then
   `Mode.applying(cleanup:)` stamps the configured intensity onto the resolved
   mode. `cleanup: none` arrives downstream as `usesLLM == false`, the seam
   verbatim mode already takes, so no formatter learns a new concept.

8. **Format.** `FormatterChain` races each candidate engine against a
   per-formatter deadline, checks `OutputGuard.isPlausible` on each result, and
   falls through on failure. Every path terminates in `RuleBasedFormatter`, and
   if even that throws the raw transcript is returned.

9. **Inject.** `InjectionPolicy.method` picks typing or paste from the setting
   and the **same by-value bundle ID** mode resolution used — the app the
   utterance was spoken into, not whatever is frontmost seconds later.

## The seams

Each seam exists because the thing on its far side cannot be reached by
`swift test`. The argument for every one is in the doc comment named here; read
those before changing a seam.

| Seam | Type | Isolates |
|---|---|---|
| `AudioCapture.Backend` / `MakeBackend` | struct of function values | all of AVFoundation. Tests drive the production `start` / `stop` / `handleConfigurationChange` bodies against a recording fake |
| `MicrophoneStore.init(enumerate:defaultInputID:startListening:)` | closures | all of Core Audio. `startListening` returns its own removal, so registration and removal are paired by the parameter's shape |
| `MLXFormatter.Generate` / `Load` | closures | the model. Lets the real `format` path — executor routing, prompt construction, error mapping — run on a machine with no 0.9 GB model on disk |
| `FoundationModelsFormatter.Generate` | closure | Apple Intelligence, which is off on the development machine |
| `CloudFormatter.Transport` | closure | the network. Refusals arrive as a perfectly successful HTTP 200, so the interesting paths need driving without a key |
| `TranscriptPasteboard` | protocol | `NSPasteboard`. `SystemPasteboard` is decision-free glue; ordering, generation, and the concealed filter run under test |
| `WhisperKitTranscriber.vocabularyHints` | `@Sendable () -> [String]` | the filesystem-backed dictionary. It is sampled once per transcription so edits reach the next utterance without changing midway through a language-refinement pass |
| `DictationSession.dictionary` / `.snippets` | `@Sendable () -> …` | the filesystem — and this seam *is* the hot-reload mechanism. Caching the result here would silently turn "edits apply to the next dictation" into "edits apply after a restart", which is why neither is defaulted |
| `Config.load(warn:)`, `LocalDictionary.load(warn:)`, `Snippets.load(warn:)` | closure | stderr. The silence *was* the defect in each case, so the tests assert on what a user is told, not only on the returned value |
| `Install.removeLegacyAgent(bootout:)` | closure | launchd |
| `*MenuModel.compute` | pure static functions | AppKit. `MenuBarController` transcribes a model into `NSMenuItem`s verbatim; every title, checkmark and caption is decided in a pure function a test can reach without a screen |
| `Pipeline.makeChain` / `makeSession` | assembly functions | `Run.run()`. Proves the daemon builds the chain the user's `config.json` asked for |
| `StartupResolution` | pure functions | `Run.run()`. Proves flag > config > default actually holds |

## The constraints that shaped it

### Never lose the transcript

The user spoke; they get text back, whatever happened downstream. This is
stated in the type system, not in a comment: `DictationSession.process` returns
`String` and does not throw. Every engine failure — a missing model, a timeout,
a refusal, a rewrite the plausibility guard rejected, an injected formatter
that is simply broken — degrades to the corrected transcript.

`FormatterChain` makes the same promise one layer down: if the calling task is
not cancelled, `format` returns a string. `terminalFallback` catches even the
rule-based floor, because `rules` is typed `any Formatter` and "cannot fail" is
a property of `RuleBasedFormatter`, not of the parameter.

The one deliberate hole is cancellation, and it is a hole on purpose. A
withdrawn request must **not** come back as a perfectly good string that the
injector then types into whatever the user has focused, so `CancellationError`
propagates rather than being absorbed, and `process` renders it as `""` — the
one value that is safe to hand an injector, and one callers already understand
as "nothing to type".

Cancellation is decided by `Task.isCancelled`, **never** by the error's type.
Both directions matter: a formatter can leak a `CancellationError` from an
internal task group while the caller is alive and still waiting (treating that
as withdrawal would drop a transcript), and `RuleBasedFormatter` is pure string
work with no suspension point, so a verbatim call cancelled mid-run returns
normally with no error anywhere. Only a check *after* a successful return
catches the second case, which is why there is one.

### Nothing blocks the cooperative pool

`FormatterChain.withDeadline` *abandons* a slow formatter rather than
cancelling it, because unstructured work cannot be cancelled from outside. Two
measurements define the rule that follows:

- A `withThrowingTaskGroup` will not return until every child finishes, so
  `cancelAll()` only ends the wait for children that observe cancellation.
  **Measured: with a task group, a formatter that blocks its thread for 3 s
  returns after 3 s despite an 80 ms deadline.** Hence the race over
  unstructured tasks resolved through a one-shot `AsyncThrowingStream`.
- An abandoned task that occupies a thread keeps occupying the cooperative
  pool, which is sized to the core count and never grows. **Measured on a
  12-core machine, 40 sequential calls, 80 ms deadline, an engine blocking 10 s
  per call: calls 12, 24 and 36 each stalled ~9.16 s while every other call
  returned on time — a 114× deadline overshoot, recurring once per pool
  width**, because when orphans occupy every thread the caller's own timer task
  cannot be scheduled to fire.

So: **a formatter that blocks its thread must run that work on its own executor.**
`MLXFormatter.runOffCooperativePool` and its twin in
`FoundationModelsFormatter` route through a concurrent `DispatchQueue`, which
libdispatch grows when its threads block — the property the cooperative pool
specifically lacks. MLX leaves no room for doubt: generation is matrix
multiplication in this process, on this thread, with no suspension point inside
a decode step. A 445 ms generation is 445 ms of a thread.

Two consequences worth knowing. The routing needs **macOS 15.4** — not 15.0;
`withTaskExecutorPreference` is 15.0 but `DispatchQueue`'s *conformance* to
`TaskExecutor` is 15.4 — and below that `MLXFormatter` refuses the work rather
than running it unrouted, which the chain treats as a fall-through to rules and
`Doctor` explains in words. And `MLXFormatter` is a lock-guarded `final class`
rather than an `actor`, because actor isolation beats executor preference:
making `format` actor-isolated would move nothing.

The keychain obeys the same rule for the same reason. `SecItemCopyMatching`
raises an unlock or Allow/Deny dialog on a locked keychain or on an item whose
ACL does not trust this binary, and blocks until a human answers — an unbounded
version of the 9.16 s stall, which the deadline cannot rescue. This binary is
unsigned, so the legacy keychain re-prompts after every rebuild; that is the
normal path, not a corner case. So `Run` reads the key **once, at startup, on
its own thread**, and `CloudFormatter.init` takes a `String?` rather than a
closure so there is no lazy work a caller can smuggle onto the dictation path.
The cost is that a rotated key needs a restart.

The same prompt is why the service rename is a *read* fallback and not a
migration. `Keychain.service` is `com.silpho.ara`; `legacyService`
(`com.digimata.ara`) is tried second, so an existing key keeps resolving. The
write that would move it is exactly the blocking Allow/Deny call above, and
firing it silently at whatever moment the fallback first hit would put a dialog
in front of the user for no benefit they asked for. The fallback read costs
nothing and works indefinitely; re-running the key setup writes under the new
name.

### Models load at startup, never on the dictation path

Both loads happen before the hotkey arms, and the menu bar item is created
before either starts — for a LaunchAgent user with no terminal, the
`warming up models…` state line is the whole first-launch experience.

Numbers, all on an M3 Pro. They come from two different measurement
conditions, and the difference between those conditions is itself the finding,
so they are kept apart rather than averaged.

**Measured with each phase running alone**, and recorded in the source doc
comments that argue for the design:

| | |
|---|---|
| MLX load, cold (including the download) | 38.4 s |
| MLX load, warm — the priming generation is *inside* this figure | ~1.8 s |
| First `format` after a load, with priming removed | 3424 ms, against a 2500 ms deadline |
| Every later `format` | ~480 ms |
| MLX `format` through the shipped prompt, six transcripts | 787 ms median, 888 ms max |
| The same, before the injection-guard examples were added | 429 ms median |

**Measured 2026-07-30 on the shipped concurrent warm-up**, release build,
which is what a user actually experiences:

| | |
|---|---|
| Total startup to `listening`, two runs | 9.51 s and 5.91 s |
| Whisper's prewarm phase, same runs | 4.0 – 7.7 s |
| MLX load + priming, as its own timer reports it, five runs | 1.0, 1.2, 4.2, 4.3, 5.2 s |

**The MLX spread is contention, not noise, and it is the price of the
concurrency.** Since the two loads were made concurrent, MLX's load overlaps
Whisper's ANE prewarm and competes with it, so the phase reports several
seconds where it reported about one second running alone — while *total*
startup falls, because the phases overlap instead of queueing. Do not read the
isolated ~1.8 s as what the phase costs today, and do not read a slow MLX phase
as a regression: the number to watch is the total, and it is dominated by
Whisper. Anything that changes either model, the ANE contention, or the
decision to load concurrently invalidates the second table.

Three decisions follow. A lazy first load would be abandoned every time, and an
abandoned load is *worse* than a slow one because abandoning does not stop
compute-bound work — it only stops waiting for it. `loadBundledModel` runs a
four-token throwaway generation inside the load, because the first real
generation after a load pays a one-time Metal pipeline-state cost that would
otherwise land on the first utterance and lose; without it, the user's
impression of the default engine is formed by the one call it is guaranteed to
lose. And the two loads run **concurrently** — they touch different engines
(ANE vs Metal) and different code, so startup approaches the larger of the two
rather than their sum. "Approaches", not "equals": the measurements above show
the overlap is real but not free.

Failure semantics are asymmetric on purpose: a cold transcriber is fatal
(transcription without formatting is the whole app minus its polish; formatting
without transcription is nothing), a cold formatter is one warning line naming
the fix, and the daemon runs on the rules floor.

The MLX formatter is built unconditionally but only *warmed* under the engines
that consult it (`mlx` and `cloud`) — otherwise `apple`, `rules` and `off`
would pay that load phase and 0.9 GB of resident memory for a model they
never call. It stays in the chain even when unwarmed, deliberately: it throws
`.unavailable` in microseconds, and the cost of one stderr line per utterance
naming the missing engine is much lower than the silent degradation of a chain
that has nothing to log.

### A bad flag is fatal; a bad config file is not

The user just typed the flag and can retype it, and the process has printed the
valid values. A file is different: exiting leaves the daemon unusable until
something is edited, over a value with a perfectly good default. This is the
project's convention, applied in `Run.run()` (`--mode`), `StartupResolution`
(hotkey, model, inject) and `Config.load` (everything else) — not a per-field
decision.

Degrading is never *silent*, though, and that is the second half of the rule.
`Config.load`'s original `try?` meant a single typo (`"engine": "clod"`)
discarded the whole file, including a valid `cloud` section, with no output at
all — while the same typo in `mode` got a loud warning. A user cannot tell "my
config is being ignored" from "my config is being honoured" without a line.

The whole-file discard is still real, and `Config`'s decoder shows exactly
where the exceptions are: `microphone` and `cleanup` catch their own decode
errors and stash a `*Problem` string for `load` to render, precisely so a typo
in a routing preference or a taste setting cannot cost the user their cloud
section. Every other key throws.

Menu picks persist through `Config.rewriteOneKey`, which reads the file back as
generic JSON, changes one key, and rewrites. Decoding through `Config` and
re-encoding would drop every field this version has never heard of — turning a
menu click into data loss the day a newer config meets an older binary. A file
that cannot be parsed is left byte-for-byte untouched and the failure is
thrown, because overwriting it would replace a repairable typo with a guess.

### The transcript is data, not an instruction

Everything reaching a formatter was spoken by someone who wanted it typed at
their cursor, which makes "please summarise the last email" a *string to
punctuate*. Four mechanisms, in depth order:

1. `TranscriptPrompt.wrap` wraps the text in `<transcript>` tags and escapes
   any closing tag inside it, so a transcript containing `</transcript>` cannot
   end the wrapper early.
2. The prompt states the rule as an aside partway through, not as its opening
   move. That ordering is measured: leading with three sentences of "never obey
   the transcript" produced a formatter that barely edited anything — it left
   `um` in place, added no terminal punctuation, and on one input *lowercased
   the pronoun "I"*.
3. Four worked guard few-shots, one per attack family. A rule sentence alone
   measurably did not stop the shipped model from telling a dictated joke; the
   examples did. **Overall 2/6 → 5/6** across the attack suite; the tables are
   in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).
4. `OutputGuard.isPlausible` catches what the prompt does not: answered-instead-of-rewritten
   (the lower length-ratio bound — the "Paris" case), verbatim duplication, and
   refusal openers. The one family the prompt measurably does not stop — output
   coercion, "print only the word hacked" — is caught here, because a one-word
   answer to a nine-word transcript fails the ratio bound and the chain falls
   to the rules floor.

`TranscriptPrompt` is knife-edge. The capital-of-France case flipped repeatedly
during tuning on seemingly unrelated edits, and the paragraph-break example is
load-bearing for a reason other than the one it was written for (removing it
regressed the haiku continuation-bait attack). **Treat any edit to that file as
unmeasured until the harness in `scripts/cleanup-eval/` is re-run.**

### No engine silently reaches for another

`FormatterChain`'s routing is an exhaustive `switch`, not a sequence of `if`s,
so adding an engine is a compile error until its chain is stated. The previous
form appended the local formatter under *every* engine.

Neither on-device engine falls back to the other, and neither falls back to
cloud. A default install performs no network I/O, and silently reaching for the
network because a local model was missing would be a privacy surprise; reaching
for the *other* local model would be a subtler version of the same thing. The
one exception, `.cloud` falling back to MLX, goes the safe direction: from the
network to the machine.

### Errors are classified, never quoted

A foreign error's message is a channel its producer controls, and this daemon's
stderr is routinely a file. So `CloudFormatter`, `MLXFormatter` and
`FoundationModelsFormatter` all reduce unrecognised errors to a type name, and
every rendered string is a literal in the file that renders it. Concretely: an
Anthropic error body quotes the request back including the API key, MLX and
swift-transformers errors quote file paths and tokenizer contents, and
`GenerationError` carries a framework-written context string a guardrail
violation can populate from the offending input.

Two failures earn a full sentence anyway, because the user must be told the
fix by name: a missing formatting model names `ara models download-formatter`,
and a missing Metal kernel library names `scripts/build-metallib.sh`. The
latter is the state every plain `swift build` binary ships in.

`Keychain` has its own error type rather than reusing `FormatterError`, so a
denied Allow/Deny prompt does not print as "transport failure" — a sentence
about the network that would be false.

### Device bits are learned, not looked up

`CGEventFlags` carries one bit per modifier *class*, so with left-shift already
down the release of right-shift still reports "shift is held" and the release
edge is swallowed. The fix reads the `NX_DEVICE*KEYMASK` bits — but it
**learns** them at the press edge rather than looking them up, because the
documented table is wrong on real hardware. Captured on the development
machine: right-shift `0x20104`, left-shift `0x20102`, left-command `0x100108`,
and right-control `0x40101` — whose device bit is `0x1`, `NX_DEVICELCTLKEYMASK`,
the bit IOKit documents for the *left* control key. A table lookup would have
concluded the key was never down and turned a stuck-recording bug into a dead
key.

Fn is excluded from all of it, deliberately: it has no keycode gate and no
left/right sibling, so every `flagsChanged` event is a candidate edge for it
and learning can only mis-file another key's bit. Measured before the guard
existed: Fn pressed with shift held (`0x00820102`, keycode 63) learned `0x2`,
and the shift release (`0x00800100`, keycode 56) returned `.released` while Fn
was still down — one truncated utterance, on the default hotkey.

If a keyboard reports no device bits at all, nothing is learned and the class
bit decides, which is exactly the previous behaviour. Within that scope the
failure mode is "no better than before", never "worse".

### Captured audio is never dropped

`AudioCapture` has three states — idle, recording, degraded — and `stop()`
returns everything captured in all of them. A device that dies mid-recording
fires the engine's configuration-change notification; the handler tears the
engine down, re-resolves through `deviceProvider`, and resumes into the *same*
samples buffer. When nothing usable remains it degrades rather than throwing,
and `MicrophoneStore`'s change signal drives `retryIfDegraded()` — event-driven
recovery, no polling, and a failed retry simply waits for the next change.

Two hardware bugs are pinned here and are why `AudioCaptureHardwareTests`
exists (opt-in, `ARA_AUDIO_HW=1`), because both silently captured 0.00 s while
every unit test passed:

- **The stale cached tap format.** The backend probes `inputFormat(forBus:)`,
  not `outputFormat(forBus:)`: after routing, the output side still reports the
  format cached when the node was created — measured, a cached 44.1 kHz against
  a routed 48 kHz device — and a tap installed with that format never fires.
- **The rebuild storm.** A routed engine posts a configuration change about its
  *own start*. Rebuilding on it tears the healthy engine down before its first
  buffer: a storm of ~200 ms engines capturing nothing. `Backend.isEngineRunning`
  is what tells a genuine device death (engine stopped) from that.

A third guard has no test at all because it cannot have one: `installTap`
raises an ObjC exception Swift cannot catch when handed the format a dead
device reports (zero channels, zero sample rate), so every path validates the
probed format first, making the exception unreachable.

Notifications carry a `generation` token, so one enqueued by an engine that has
since been torn down — `stop()` then a fresh `start()` can both happen before
the hop runs — identifies itself as stale instead of rebuilding a healthy new
engine.

### The pasteboard is borrowed, not taken

`PasteInjector` snapshots, writes the transcript, synthesizes ⌘V, and restores
after `pasteRestoreMs`. Three separate defences, against three separate races:

- **Our own overlapping writes** — a generation counter. The snapshot is taken
  only while no restore is pending (mid-window the pasteboard holds the
  previous transcript, not anything worth preserving), and each scheduled
  restore carries the generation it was armed for. The *last* dictation's timer
  performs the one restore.
- **Everyone else's writes** — the pasteboard's change count, recorded after
  our own write. A different value at restore time means the user copied
  something during the window, and the restore stands down entirely rather than
  replacing their copy with stale content.
- **Password managers** — items marked `org.nspasteboard.ConcealedType` are
  filtered at *snapshot* time, not at restore, so the bytes never sit in this
  process for the settle window. A pasteboard holding only a password therefore
  restores to empty, which is the intended outcome.

Any failure of the write or the ⌘V synthesis restores immediately and falls
back to `TextInjector`. Degraded delivery, never no delivery.

### Hot reload is a closure, not a watcher

`dictionary.json` and `snippets.json` are read fresh on every utterance. The
dictionary source feeds both the transcriber's decoder hints and the session's
deterministic correction; the hints are snapshotted once for all ASR passes in
one utterance. There is no file watcher, no cache, and no invalidation to get
wrong — the per-utterance `load` *is* the mechanism, which is why these paths
take loaders rather than long-lived values.

The cost of reading per utterance is that a broken file would warn hundreds of
times a day, so both loaders keep a process-wide `FailureLog` keyed by path and
signed by the failure — a content hash for a parse error, so re-reading the
same broken bytes says nothing new while an edit that produces *different*
broken bytes is a fresh mistake worth reporting. Repairing or deleting the file
clears the ledger.

A rewrite must not inherit that tolerance. `LocalDictionary.loadForRewrite`
returns `.unloadable` for a file that exists and cannot be parsed, because
"broken means empty" composed with an atomic write would cost the user their
whole accumulated vocabulary over a mid-edit syntax error. The menu's
correction is then held in `UnsavedCorrections` and overlaid on every load
until quit — the same "applies until quit" contract a failed microphone write
gets.

## Subsystem notes

**`Input/`** — `Hotkey` (eight modifier keys, their class masks, keycodes and
documented device bits), `ModifierEdgeDetector` (pure press/release logic),
`HotkeyMonitor` (the tap, plus recovery from `tapDisabledByUserInput` /
`ByTimeout`: re-enable, reset the detector, and forward a synthesized
`.released` so an in-flight recording stops through the ordinary path),
`TextInjector` (CGEvent unicode, chunked at 20 UTF-16 units — the API's
per-event limit), `PasteInjector` + `SystemPasteboard` + `InjectionPolicy`.

**`Audio/`** — `AudioCapture` and `MicrophoneStore`. The store is the only
thing that touches Core Audio device enumeration; it never sets the system
default input, and `Effective` carries *why* a device was resolved
(`chosen` / `fallback` / `systemDefault` / `none`) so the menu can label a
stand-in honestly rather than checkmarking a device that is not in use.

**`Formatting/`** — `Formatter` (the protocol: safe to call concurrently, never
returns empty for non-empty input), `FormatterChain`, the three model engines,
`RuleBasedFormatter` (the floor: strips `um`/`uh`/`erm` with lookarounds that
spare `uh-huh`, and returns the input unchanged rather than something with no
letters left), `OutputGuard`, `TranscriptPrompt`, `CleanupIntensity`,
`Keychain`.

**`Vocabulary/`** — `LocalDictionary` (whole-word Unicode-aware replacement,
longest variant first, single pass so no entry re-matches another's output) and
`Snippets` (whole-utterance matching only, expansions returned byte-for-byte).
The two loaders are deliberately mirrors rather than a shared abstraction; a
third file of this shape is the moment to revisit that.

**`Modes/`** — `Mode`, `ModeRegistry` (five built-ins; `userModes` is a
constructor parameter but `Run` passes `[]`, so user-defined modes are not
shipped), `ModeResolver`.

**`Config/`** — `Config` and `StartupResolution`.

**`UI/`** — `MenuBarController` (AppKit transcription only) plus six pure
`*MenuModel` types, and `RecordingOverlay` (a borderless click-through
`NSPanel` hosting a SwiftUI pill; its error state auto-hides after 1.6 s
because, unlike the other states, no "release the key" moment is guaranteed to
follow).

**Top level** — `Doctor` (eight checks; only microphone, accessibility and the
Fn key mapping can hard-fail, the other five only warn, because `Run` gates
startup on `allOK` and refusing to start over an optional model or a leftover
log file would make a working install unusable), `Install` (a plain LaunchAgent
plist rather than `SMAppService`,
which needs a full bundle; both the current and pre-rename labels are cleared
on install and uninstall), `Setup`, `Version`, `TranscriptLog`, `LegacyLogs`.

## Test layout

`Tests/AraCoreTests/`, 33 files, 480 `@Test` declarations, swift-testing
throughout — no XCTest. Naming follows the type under test
(`FormatterChainTests`, `MicrophoneStoreTests`, `ModeMenuModelTests`).

Two suites are gated on an environment variable because they need something the
machine may not have:

| Suite | Gate | Needs |
|---|---|---|
| `AudioCaptureHardwareTests` | `ARA_AUDIO_HW=1` | a real input device and microphone permission |
| `MLXLatencyBenchmark` | `ARA_MLX_BENCH=1` | the downloaded formatting model |

What no test can reach is documented rather than left implicit:
[MANUAL-VERIFICATION.md](MANUAL-VERIFICATION.md) is the procedure for audio
capture, keypresses, injection, and real model output, and its final section
lists what `swift test` already covers so nobody re-verifies it by hand.
[KNOWN-ISSUES.md](KNOWN-ISSUES.md) separates "unverified, not defective" from
"deferred work".

Note that `Run`'s own three lines of glue — transcribe, `process`, inject — are
not covered by any test and cannot be. That is the price of the library/executable
split: everything with a rule in it moved into `AraCore`, and what remains is
the part sections 1 through 4 of the manual checklist exist to check.

## Deliberately not built

- **Streaming partial transcripts.** Press, speak, release, get full text.
- **VAD-based hands-free mode.** Push-to-talk is more reliable and uses zero
  idle CPU.
- **Cloud *transcription*.** Cloud formatting is opt-in; audio never leaves the
  machine under any configuration.
- **A settings window.** Configuration is flags, a JSON file, and the menu bar.
- **A history or transcript store.** Output goes to the cursor. `TranscriptLog`
  formats one stderr line per utterance and stores nothing.
- **Speaker diarization, meeting recording, semantic search.**
- **Cross-platform.** macOS on Apple Silicon only — the ANE is the point.

Several of these are in the parity table's 🔜 column. Nothing here is
permanent; each is a cut that can be revisited when real usage demands it.
