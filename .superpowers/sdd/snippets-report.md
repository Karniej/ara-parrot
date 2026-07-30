# Voice snippets — implementation report

Branch: `feature/snippets` (from master tip `7cb9981`)
Status: **complete** — full suite green (331 tests, up from 299), release build green.

## Commits

1. `b35a714` feat: add voice snippets — whole-utterance triggers with verbatim expansions
   - `Sources/AraCore/Vocabulary/Snippets.swift` (new), `Tests/AraCoreTests/SnippetsTests.swift` (new, 25 tests)
2. `a0cc9d2` feat: short-circuit a snippet hit past mode resolution and the formatter
   - `Sources/AraCore/Session/DictationSession.swift`, `Sources/AraCore/Session/Pipeline.swift`,
     `Tests/AraCoreTests/DictationSessionTests.swift` (+5), `Tests/AraCoreTests/PipelineTests.swift` (+2)
3. `6bb8647` docs: document voice snippets — file format, matching contract, manual checks
   - `README.md` ("Snippets" section), `docs/MANUAL-VERIFICATION.md` (section 9quinquies, log-line table, coverage summary)

## What was built

- `Snippets`: `~/.config/ara/snippets.json` as `[{trigger, expansion}]`, loaded fresh per
  utterance (hot reload), never throws, missing file = feature off and silent, broken file
  warns once per distinct failure (content-hash ledger, resets on repair) with a `snippets:`
  stderr prefix. An exact mirror of `LocalDictionary.load`, per the settled design.
- `Snippets.normalize` (pure, public, exhaustively tested): full Unicode case folding
  (Polish diacritics included), surrounding-whitespace trim, terminal punctuation stripped
  (`.!?,;:…`, in any trailing run, whitespace-interleaved too), internal whitespace collapsed.
  Deliberately NOT diacritic-insensitive: "krakow" ≠ "kraków", pinned by test.
- `Snippets.expansion(for:)`: whole-utterance equality under normalization, applied to both
  sides so a trigger hand-written as "Insert my link." still fires. First entry wins duplicate
  triggers; an entry with an empty expansion is inert (it would erase spoken words).
- Pipeline position: in `DictationSession.process`, after dictionary correction (a misheard
  trigger word can be dictionary-fixed first — pinned by test), before mode resolution. A hit
  returns the expansion as the final output: no mode resolved, `onModeResolved` not called,
  formatter never consulted, no OutputGuard — expansion reaches the injector byte-for-byte,
  newlines included. `Task.isCancelled` is checked before returning the expansion (same
  unobservable-cancellation hole the post-format check closes).
- Never-lose-the-transcript holds: `expansion(for:)` is pure/non-throwing, every load failure
  is empty snippets, no match = normal processing. `process` still never throws.
- `Pipeline.makeSession` gains `snippetsURL:`/`snippets:` mirroring the dictionary's
  URL-or-source pattern. `Sources/parrot/Parrot.swift` needed **no change**: the default
  loader (`Snippets.load(from: Snippets.defaultURL)`) is wired by `makeSession` itself,
  and there is no unsaved-state overlay because snippets are file-only in v1.
- No menu UI in v1, by design (multiline expansions vs. NSAlert fields) — documented in
  README and MANUAL-VERIFICATION 9quinquies.

## Tests

- Red-first at both steps: `cannot find type 'Snippets'` before commit 1;
  `extra argument 'snippets'/'snippetsURL' in call` before commit 2. Green after each.
- 331/331 passing (`swift test`), 23 suites; new coverage: 25 (Snippets) + 5
  (DictationSession short-circuit/near-miss/ordering/mode-callback/hot-reload) + 2
  (Pipeline wiring incl. broken-file harmlessness through the production assembly).
- `swift build -c release` green.

## Duplication note (for the next review to weigh)

`Snippets.load` + `FailureLog` + `warnToStderr` are a deliberate copy of the
`LocalDictionary` loader pattern (~70 lines), per instruction: no shared abstraction was
extracted. Two similar loaders now exist in `Sources/AraCore/Vocabulary/`; a third file of
this shape is the point at which a generic tolerant-loader is worth extracting. The
normalization/matching halves share nothing and would not benefit.

## Concerns

- `TextInjector` posts expansions via `CGEventKeyboardSetUnicodeString`; `\n` in an
  expansion is expected to insert a newline in ordinary fields, but this is exactly the
  class of thing only MANUAL-VERIFICATION 9v-a can prove (some fields treat Return as
  submit, e.g. chat inputs — a snippet with newlines dictated into Slack may send
  mid-message; noted as platform behavior, not a bug in the snippet machinery).
- Terminal-punctuation set is `.!?,;:…` — closing quotes/brackets after punctuation
  ("insert my link.") with a trailing quote) are not stripped; Whisper essentially never
  emits those utterance-finally, so this was left out of v1 rather than guessed at.
- A snippet hit updates no menu-bar mode label (no mode is resolved). The label keeps its
  previous value; harmless, documented in the `onModeResolved` init doc.
