# Custom Vocabulary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** A hot-reloaded local dictionary that deterministically corrects misheard terms in every transcript before any formatting engine sees them, plus a menu-bar form to add corrections.

**Architecture:** A pure `Dictionary` replacement engine loaded per-utterance from `~/.config/ara/dictionary.json`, applied at the top of `DictationSession.process`; a menu item opens a two-field form whose merge logic is pure and whose write-back keeps the file hand-editable.

**Tech Stack:** Swift 6.3, SwiftPM, swift-testing. Spec: `docs/superpowers/specs/2026-07-30-custom-vocabulary-design.md` — its decisions bind; this plan is contracts, not code (derive API shapes from the SDK and compiler).

## Global Constraints

- **Never lose the transcript.** Any dictionary failure — missing file, malformed JSON, regex construction failure — yields the input text unchanged and never throws out of `process`.
- **Hot reload:** the file is read on every utterance; edits apply to the next dictation with no restart. A malformed file warns on stderr and behaves as empty. Warn once per distinct failure, not per utterance — a broken file must not spam a log line 200 times a day.
- **Applied before the formatter chain, on every path including verbatim mode.** The chain, engines, and modes are untouched.
- **Whole-word, case-insensitive, Unicode-aware** (letter/digit/underscore boundaries — the user dictates Polish; `ł`, `ż`, diacritics are word characters). Longest variant first. Replacement text with `$` stays literal. Single pass: one entry's output is never re-matched by another entry.
- **All UI on `@MainActor`.** The form is a thin AppKit shell over pure merge logic.
- **File writes are best-effort**: failure costs one stderr line, the in-memory state still applies this session. Written JSON is pretty-printed and stable-ordered so the file diffs cleanly and stays hand-editable.
- Package platform stays `.macOS(.v14)`. `public` means "the executable consumes it". Nothing on the dictation path may block the cooperative pool (file read is small local I/O — fine — but no network, no locks held across it that the audio tap needs).

---

### Task 1: Dictionary engine + pipeline integration

**Files:**
- Create: `Sources/AraCore/Vocabulary/LocalDictionary.swift`
- Modify: `Sources/AraCore/Session/DictationSession.swift`, `Sources/AraCore/Session/Pipeline.swift`
- Test: `Tests/AraCoreTests/LocalDictionaryTests.swift`, extend `Tests/AraCoreTests/DictationSessionTests.swift` (or wherever `process` is currently pinned — read the existing session tests first and follow their seam)

**Interfaces produced (Task 2 consumes):** a `LocalDictionary` type exposing: `struct Entry { canonical: String; variants: [String] }`, `load(from: URL) -> LocalDictionary` (never throws to callers — malformed → empty + warning callback), `apply(_ text: String) -> String`, `adding(heard: String, canonical: String) -> LocalDictionary` (pure merge/dedupe), `entries` read, and encode-to-stable-pretty-JSON. The session gains a dictionary source injected the way its other collaborators are (read `DictationSession`'s existing init/seams first and match).

**Contract:**
1. `apply` semantics per the Global Constraints, exhaustively unit-tested: the three ported PR-#6 specs (literal `$` in canonical; a variant that is a prefix of a longer word does not fire inside it; whole-word boundaries), plus: case-insensitive match preserving no case from the variant (canonical is inserted verbatim), longest-variant-first across entries, Polish diacritics as word characters (variant `osrodek` does not match inside `ośrodka`? — no: diacritic-insensitive matching is NOT in scope for `apply`; the boundary test is that `ł`/`ż` count as letters for boundary purposes), single-pass no-chaining (entry A's output containing entry B's variant is not rewritten).
2. `load` reads the URL fresh each call; missing → empty; malformed → empty + one warning via an injected warn callback, deduped per failure signature (mtime or content hash — your choice, tested).
3. `process` applies the dictionary to the raw transcript before mode resolution/formatting; a test proves order (dictionary output is what the formatter receives — drive with a fake formatter that records its input) and that verbatim mode also gets corrections.
4. Wiring in `Pipeline`/`makeSession` follows the existing dependency style; the dictionary URL defaults next to `Config.defaultURL` (`dictionary.json` in the same directory) and is overridable for tests.

- [ ] **Step 1: Write the failing tests** (engine semantics, load tolerance, warn dedupe, process ordering).
- [ ] **Step 2: Run them, confirm they fail.**
- [ ] **Step 3: Implement `LocalDictionary`.**
- [ ] **Step 4: Wire the session + pipeline.**
- [ ] **Step 5: Full suite green** (`swift test`; 254 pre-exist), release build clean.
- [ ] **Step 6: Commit.**

---

### Task 2: Menu form + persistence + docs

**Files:**
- Modify: `Sources/AraCore/UI/MenuBarController.swift`, `Sources/parrot/Parrot.swift`, `README.md`, `docs/MANUAL-VERIFICATION.md`
- Test: `Tests/AraCoreTests/LocalDictionaryTests.swift` (merge/round-trip additions)

**Contract:**
1. Menu item "Add dictionary correction…" below the Microphone submenu; opens a two-field form (heard → should be) — an `NSAlert` with accessory views is acceptable and matches a single-binary app; no new windows/xibs. Empty fields → no-op. The form is the only AppKit; validation and merge are `LocalDictionary.adding` (pure, tested): a variant already mapped to another canonical moves; canonical matching for dedupe is case- and diacritic-insensitive; adding an existing variant to its own canonical is a no-op.
2. Save writes the stable pretty JSON next to the config file, best-effort per Global Constraints; the next utterance picks it up via hot reload — no other wiring needed (a test pins that `load` after `adding`+write round-trips).
3. Docs: README gains a "Dictionary" section (file format example + menu flow + hot reload); MANUAL-VERIFICATION gains: add a correction via the menu → dictate the misheard form → the canonical is typed; edit the file by hand → next utterance uses it; break the JSON → dictation still works, one warning.

- [ ] **Step 1: Write the failing tests** (merge/dedupe/moves, round-trip through real files).
- [ ] **Step 2: Run them, confirm they fail.**
- [ ] **Step 3: Implement form + write-back.**
- [ ] **Step 4: Full suite + release build.**
- [ ] **Step 5: Commit, including docs.**

## Self-Review

**Coverage:** engine (T1c1), hot reload + tolerance (T1c2), pipeline position incl. verbatim (T1c3), menu + merge (T2c1), persistence + round-trip (T2c2), docs (T2c3). Spec's out-of-scope list respected — no ASR biasing, no per-mode vocabularies.

**Known risk:** regex-based whole-word boundaries with Unicode classes are easy to get subtly wrong — that is why the boundary semantics are pinned by tests written first, and why `apply` is pure enough to test exhaustively.

**Deliberately not in scope:** ASR biasing (WhisperKit prompt tokens), per-mode vocabularies, import/export, diacritic-insensitive *matching* (dedupe only).
