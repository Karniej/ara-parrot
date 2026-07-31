# Warm-up overlay — implementation report

Branch `feature/warmup-overlay`, three commits on `1faf6e4`.

## 1. Was download progress obtainable?

### Transcription model (WhisperKit): **yes**, with a caveat about its weighting.

Evidence, in order:

- `WhisperKit.init` → `setupModels` (`WhisperKit.swift:303–345`) already calls
  `WhisperKit.download(variant:downloadBase:useBackgroundSession:from:token:endpoint:progressCallback:)`
  itself whenever no `modelFolder` is given and `download` is true — which is
  exactly the configuration `WhisperKitTranscriber.warmUp` used. It passes **no**
  `progressCallback`, which is why a 1.5 GB first run reported nothing.
- Option (b) — observing the instance's `progress` property (`WhisperKit.swift:45`)
  — is ruled out for the reason the brief anticipated: the property does not
  exist until `init` returns, and `init` is what performs the download. It is
  also a *transcription* progress object, not a download one.
- Option (a) works and is a strict superset of what the library was doing:
  call `WhisperKit.download(variant:progressCallback:)` ourselves, then
  construct with `modelFolder: folder.path, download: false`. Same repo, same
  variant string, same hub cache, same `HubApi` defaults
  (`HubApi(downloadBase: nil)` resolves to `~/Documents/huggingface`, identical
  to `HubApi.shared`), and the same etag verification on a warm start — the
  self-healing re-fetch of a truncated file still runs. `download: false` on
  the config only means "the folder is already decided".

**Caveat, stated in the code's own doc comment:** the percentage is
*file-count weighted*, not byte weighted. `HubApi.snapshot`
(`swift-transformers/Sources/Hub/HubApi.swift:662–663`) builds
`Progress(totalUnitCount: filenames.count)` and gives every file one unit
regardless of size. For `openai_whisper-large-v3-v20240930_turbo` the bytes sit
in three `weights/weight.bin` files among roughly two dozen, so the number
advances in lumps. Byte weighting is not reachable without extra HTTP HEAD
requests per file: `getFilenames` returns names only, and the per-file handler
(`HubFileDownloader.download`) reports a fraction, never a byte count. This is
also the exact measure `ara models download-formatter` has always printed, so
the two surfaces are consistent.

I judged that real-but-lumpy is honest and worth showing, and documented the
weighting where the callback is built rather than implying bytes. Two guards
keep it from lying:

- The stream is coalesced to **one report per whole percent** and is
  **monotonic** (`ProgressCoalescer`) — a percentage that goes backwards from
  an out-of-order read would read as a bug.
- **100% is suppressed.** On a fully cached start `HubFileDownloader.download`
  returns early without invoking its handler, so the only callback is
  `snapshot`'s terminal one at fraction 1.0; without the guard a warm start
  would flash "downloading… 100%" over "loading…".

The first phase label is also decided from disk (`WhisperModelStore.isPresent`)
rather than waited for, because the download's first report cannot arrive until
the hub answers with a file listing — and calling a warm start's etag check
"downloading" for those seconds would be a claim the pill then has to retract.

### Formatting model (MLX): **no**, and deliberately so.

`MLXFormatter.warmUp` does not download — by design (`MLXFormatter.swift`: the
0.9 GB fetch is a CLI action, and the loader used is the *directory* overload
specifically so "this call cannot reach the network" is a property of the API).
So there is no download to report progress for during a daemon warm-up.

The load itself exposes nothing: `loadModelContainer(from directory: URL, using:)`
(`mlx-swift-lm/Libraries/MLXLMCommon/ModelFactory.swift:404–411`) has **no**
`progressHandler` parameter. The three overloads that do take one
(`ModelFactory.swift:305, 337, 361`) are all the `from downloader:` variants —
the download path the formatter must not take. There is also no way to observe
the Metal specialisation cost of the priming generation.

`MLXModel.download(progress:)` (the CLI path) already surfaces
`fractionCompleted` from the same `HubApi.snapshot`, with the same file-count
weighting, and `ara models download-formatter` already prints it. Unchanged.

So the formatter's warm-up phase is indeterminate text —
"preparing the formatting model…" — and no percentage is invented for it.

## 2. State shape

Pure, in `Sources/AraCore/UI/WarmupStatus.swift`:

```swift
public struct WarmupStatus {           // Equatable, Sendable
    public enum Formatter { case notLoading, loading, ready }
    public let modelID: String
    public var transcriber: TranscriberWarmup?   // nil == warm
    public var formatter: Formatter
    public var message: String?                  // nil == nothing left to wait for
    public var isWarming: Bool { message != nil }
    public static func readyMessage(hotkeyLabel: String) -> String
}
```

with, in `Sources/AraCore/Transcription/WhisperKitTranscriber.swift`:

```swift
public enum TranscriberWarmup { case downloading(percent: Int?), loading }
```

Three decisions worth naming:

- **`isWarming` is defined as `message != nil`.** The gate the press handler
  consults and the sentence the pill shows are the same fact, so they cannot
  disagree — a press landing in a gap between two different answers would be a
  recording into a cold transcriber.
- **The transcriber outranks the formatter.** One pill, two concurrent loads;
  the transcriber is the one that gates dictation and the formatter loads
  inside its shadow. Once the transcriber is warm the formatter gets the line,
  which is why the warm-up task sets `transcriber = nil` on success rather than
  only at the end.
- **`Formatter.notLoading` is a state.** `rules`, `apple` and `off` never load
  the formatting model, so the status must not mention it.

The mutable holder is `WarmupState`, a `@MainActor final class` in `Ara.swift`
next to `ManualMode`, as the brief suggested. It carries the status, the
overlay, the menu bar, and two booleans:

- `showingStatus` — set by a press the gate turned away, cleared by that
  press's release. It is also the **latch** the release handler checks, rather
  than a second `isWarming` test: the warm-up can finish while the key is held,
  and a release that fell through would call `capture.stop()` on a capture that
  was never started.
- `transcriberSettled` — the gate opens one way. Progress callbacks arrive on
  arbitrary `URLSession` threads and hop to the main actor unordered, so a
  stale `.downloading(99)` landing after the `nil` must not re-close the gate
  behind a recording.

Threading: coalescing happens at the source (inside the transcriber, before the
hop), so it is one hop per visible change; the hop is `Task { @MainActor in … }`
and the callback body is nothing else.

`RecordingOverlay.State` gains `case warmingUp(String)`, rendered in the pill's
existing language: the `.error` case's shape (words in place of bars) in the
waveform's own blue rather than the error red, with a small spinner beside it —
the sentence says what is happening, the spinner says it is still happening,
which is the question a two-minute wait actually raises. It does **not**
self-hide (unlike `.error`): the key release takes it down.

One unrelated latent bug was fixed while there: `show()`'s deferred
first-appearance state set is now token-guarded, because a newer state applied
directly in that window could be overwritten by the stale deferred one. Not
reachable before — nothing repainted a pill twice in a runloop turn — and
reachable now that a percentage can tick while the pill is appearing.

## 3. What did not change

- **Recording is not weakened.** The arming point is identical to before: the
  gate opens in the warm-up task's completion, after *both* loads, exactly
  where `armHotkey()` used to be called. Only the feedback moved earlier. A
  press before that shows status and does nothing else — no capture, no
  `setRecording`, no sound.
- **The warm dictation path is byte-for-byte the old one** past the two gate
  checks.
- The overlay's existing states are untouched in behaviour.

One deliberate behaviour change beyond the brief, called out here: registering
the event tap now happens before `app.run()`, so a permissions failure throws
`ExitCode(1)` (as the old comment wished it could) instead of `Darwin.exit(1)`,
and it happens in milliseconds instead of after a model download. Same two
stderr lines, same exit status.

## 4. Expectation before the wait

- Model submenu rows now read `whisper-base.en · 145 MB · on disk` or
  `whisper-large-v3-turbo · 1.6 GB download`.
- `ara models list` gets the same column plus a legend line. Verified against
  this machine's real cache: base.en and large-v3-turbo report on disk,
  small.en reports `488 MB download`.
- Sizes render in the unit the question is asked in — `ModelSize.label`.
- The on-disk rule generalises `MLXModel.isPresent` (config + weights, because
  an interrupted download leaves the directory behind) into
  `LocalModelDirectory`, with `WhisperModelStore` answering it for WhisperKit's
  hub layout. `MLXModel.isPresent` now delegates to it.

## 5. Not verified without launching the daemon

Per instruction, the daemon was never started. Unit tests cover every pure
rule; the following are reasoned from the source and **not observed running**:

1. **The pill's text fits the capsule.** The panel was widened 280 → 460 pt
   because `fixedSize()` refuses to wrap and the longest line
   ("downloading whisper-large-v3-turbo… 45%", ~39 chars at 12 pt) exceeded 280.
   The capsule hugs its content and the surplus panel is clear and
   click-through, so the extra width should be invisible — the file's own
   existing comment makes that argument for the original 280. Worth one glance.
2. **The spinner + text layout** in `.warmingUp` (an `HStack` at height 22).
3. **The live percentage on a real cold download.** Reproducing it means
   deleting a 1.5 GB model. The lumpiness described above is predicted from
   `HubApi.snapshot`'s unit accounting, not measured.
4. **The hop timing** — that a press during warm-up paints within a frame.
5. **`ara models download <id>`'s carriage-return progress line** on a model
   that actually needs fetching.

## 6. Verification run

- `swift build` — clean (one pre-existing `PasteInjector` Swift 6 warning,
  untouched).
- `swift build -c release` — clean.
- `swift test` — **589 tests in 52 suites passed** (557 at base, 32 added).
  One flake seen on a loaded machine:
  `CloudFormatter/"format suspends across the transport…"`, a latency
  measurement unrelated to this branch; green on re-run and on every run since.
