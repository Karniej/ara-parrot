# Language detection — implementation report

Branch `feature/language-detection`, five commits off `b99a42b`.
541 tests green (484 at base, +57), `swift build -c release` green.

## The two WhisperKit lines, verified

Both confirmed in `.build/checkouts/WhisperKit` at the pinned revision.

`Sources/WhisperKit/Core/Configurations.swift:226`

```swift
self.detectLanguage = detectLanguage ?? !usePrefillPrompt // If prefill is false, detect language by default
```

`usePrefillPrompt` defaults to `true` (`Configurations.swift:195`), so an
unspecified `detectLanguage` resolves to **false**.

`Sources/WhisperKit/Core/TranscribeTask.swift:312`

```swift
if textDecoder.isModelMultilingual, options.language == nil, options.detectLanguage {
```

With `detectLanguage == false` this branch is unreachable, so
`WhisperKitTranscriber.swift:32`'s bare `pipeline.transcribe(audioArray:)` could
never detect anything. Confirmed.

## Design: monitored languages, not auto-vs-fixed

Adopted the `aivars/parrot` shape (MIT, © Andrew Jones) as directed —
reimplemented against AraCore's types, credited in doc comments on
`LanguageCatalog`, `LanguageSetting`, `LanguagePolicy` and
`WhisperKitTranscriber.refine`. Their `LanguagePolicyTests` cases are ported as
specifications in `Tests/AraCoreTests/LanguageTests.swift`.

`selectMonitoredLanguage`, `comparisonLanguage` and `chooseLanguage` are pure
with the bias injectable, and `LanguagePlan.resolve` — model kind × setting →
`DecodingOptions` — is the pure first-pass function the brief required.

### One deliberate divergence: no `detectLangauge` call

Their ambiguous path costs three passes because it calls
`pipeline.detectLangauge(audioArray:)` for a probability distribution. Against
this WhisperKit that call cannot deliver one. `TextDecoder.detectLanguage`
(`TextDecoder.swift:697–703`) fills `languageProbs` only from tokens the greedy
sampler actually emitted:

```swift
for (tokenIndex, token) in sampleResult.tokens.enumerated() {
    if tokenizer.allLanguageTokens.contains(token) { languageProbs[language] = ... }
}
```

Measured live: the returned table held **one** entry. So
`selectMonitoredLanguage` would score every monitored language at `-.infinity`
and take its degradation path (detected → lastUsed → first monitored)
regardless — and the call costs a measured **515 ms**, because it re-runs the
mel and the encoder. Ara takes that degradation directly and skips the call.
Worst case is two passes, not three. `selectMonitoredLanguage` keeps its
ranking and is passed an empty table, documented, so it becomes correct for
free if WhisperKit ever exposes a real distribution.

## Default-behaviour decision

**Absent `language` key ⇒ `auto`.**

- On an English-only model (`TranscriptionModel.isEnglishOnly`, i.e. no
  language other than `en` in the registry entry) `LanguagePlan` collapses
  every setting to `language: nil, detectLanguage: false` — byte-identical to
  `DecodingOptions()`'s defaults, which is exactly what the daemon did before
  this branch. Nobody on the default `whisper-base.en` sees any change, and
  nothing warns.
- On a multilingual model `auto` means `detectLanguage: true`. This is the fix.
  A user who downloaded 1.6 GB of multilingual weights did so to speak more
  than one language; defaulting them to the English prefill is the reported
  bug, and "you must also set a config key you were never told about" is not a
  fix.

The asymmetry is why `LanguagePlan.resolve` takes the model: it is one setting
with two meanings, and both are defensible only because the model decides which
applies.

**English-only + non-English language** warns once at startup, naming the bad
code, the model, and the multilingual models that would work. It cannot be
honoured, so it is not silently swallowed — and in the submenu every row is
disabled with a caption saying which models are not English-only.

## Live apply, verified before claiming it

The caption is **"applies to the next utterance"**, not the house
"applies on restart". Checked rather than assumed: the transcriber is
constructed at startup, but `DecodingOptions` are built *inside* `transcribe`,
so `WhisperKitTranscriber.setLanguage` (actor-isolated, therefore only ever
landing between utterances) changes the next dictation. The menu is wired like
the Microphone submenu for that reason: the live apply cannot fail and happens
first; the config write is best-effort and its failure means "applies until
quit".

## What was measured, and what was not

`Tests/AraCoreTests/LanguageLatencyBenchmark.swift`, opt-in behind
`ARA_LANG_BENCH=1`. Audio synthesised with `say` (Zosia for Polish, Samantha
for English) into 16 kHz mono float — a committed WAV would be a megabyte
nobody reviews. Model `whisper-large-v3-turbo`, warm, one sample per row,
5.95 s of Polish speech unless noted.

| pass | ms |
|---|---|
| pinned `pl`, one pass | 855 |
| automatic (one pass with detection) | 960 |
| pinned `en` on the Polish audio | 1140 |
| pinned `en` on a 1.28 s Polish clip | 692 |
| `detectLangauge()` standalone | 515 |
| short (1.28 s) clip, automatic | 544 |
| English clip, automatic | 1555 |

Read off that:

- Detection *inside* `transcribe` is nearly free (~100 ms) — it reuses the
  encoder output.
- A monitored set of two languages costs one whole extra pass (~855 ms, roughly
  double) but **only** on an utterance whose detected language differs from the
  previous one's. A stable session pays ~100 ms.
- This is the transcription phase, separate from the formatter chain's 2500 ms
  per-engine deadline. It lengthens total latency; it does not eat the
  formatting budget.
- Run-to-run variance is real (the English row moved 724→1555 ms across two
  runs). These are single samples on a machine with other work on it; treat
  them as order-of-magnitude, which is what the decisions above need.

**The uncomfortable finding.** With today's defaults the Polish clip was
labelled `language: en` — the bug, reproduced — but the *text* came back as
correct Polish. Pinning `en` explicitly also produced correct Polish. So on
clean audio `whisper-large-v3-turbo` overrides the wrong prefill. The defect is
therefore stated as "the language is never detected", not "your Polish comes
out English". Whether real dictation — noisier, accented, shorter, and the
condition the user actually reported — degrades further is **not measured** and
cannot be from here: it needs a human, a microphone, and the manual checklist.
That is written into `docs/KNOWN-ISSUES.md` rather than smoothed over.

**Also not measured**: the refinement path end to end against real bilingual
speech. The pieces are unit-tested and the pass costs are measured; the
composite behaviour over a real session — does the bias actually stop the
flapping — needs the same human.

## The language list

Fourteen, ordered alphabetically by English name so no ranking has to be
defended: Chinese, Czech, Dutch, English, French, German, Italian, Japanese,
Korean, Polish, Portuguese, Russian, Spanish, Ukrainian.

The accepted *set* is WhisperKit's own `Constants.languageCodes` (asserted
equal by test, not copied), so all 99 work when written into `config.json` by
hand and a WhisperKit upgrade needs no edit here. The fourteen are only what
the submenu shows — every extra row is a row the user has to *not* tick, since
the setting is a multiple choice. English is in it because every other default
assumes it; Polish because it is the language whose misdetection is this bug.
Names are hardcoded rather than `Locale.localizedString(forLanguageCode:)`,
which would answer in the user's locale and put Polish names in an
otherwise-English menu.

## Noted for follow-up, not implemented

- **ASR-level vocabulary hints.** The prior art feeds per-language vocabulary
  into WhisperKit as `promptTokens` (`updateVocabularyHints`,
  `promptTokens(for:)`) — decoder biasing, strictly stronger than and
  complementary to post-ASR replacement. Ara does none.
- **`LocalDictionary` entries have no language.** Their `CorrectionStore` is
  per-language. Ours applies an English correction to a Polish transcript,
  which is a real gap now that multilingual dictation works.

Both are in `docs/KNOWN-ISSUES.md` under deferred work.

## Concerns

1. The severity finding above. The fix is unambiguously correct (the language
   metadata was wrong and detection was unreachable), but it may not be the
   whole of what the user experienced, and I could not reproduce their symptom.
2. Single-sample timings on a busy machine.
3. `LanguagePolicy.selectMonitoredLanguage`'s probability ranking is currently
   unreachable in production (always passed `[:]`). Kept deliberately, tested,
   documented — but it is untaken code until WhisperKit changes.
4. The Language submenu has never been rendered. `MenuBarController` is a
   verbatim transcription of a unit-tested model, as the other submenus are,
   but nothing has drawn it — the daemon was not launched, per instructions.
