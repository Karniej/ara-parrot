# Custom Vocabulary Design

Approved 2026-07-30 (user: "Implement a custom vocabulary system").

## Problem

The ASR model consistently mishears names, product terms, and jargon
("parrot" itself, "Ara", people's names). There is no way to teach it. This
is the deterministic floor of the custom-vocabulary feature; ASR biasing via
WhisperKit prompt tokens can layer on top later and is out of scope here.

## Design

Reference: upstream PR #6 (evaluated ADAPT — the mechanism is right, the code
targets pre-fork internals and predates the MIT license, so reimplement).

**Dictionary file** — `~/.config/ara/dictionary.json` (same directory as the
config file, same tolerant-load philosophy): a list of entries
`{ "canonical": "Ara", "variants": ["ara", "aara", "arra"] }`. Hot-reloaded:
read on every utterance, so edits apply to the next dictation with no
restart. A missing file means an empty dictionary; a malformed file warns on
stderr once per change and behaves as empty — never blocks dictation.

**Replacement engine** — a pure function `apply(_ text: String) -> String`:
case-insensitive whole-word matching with Unicode-aware boundaries
(letters/digits/underscore lookarounds), longest variant first so "New York
Times" beats "New York", replacement templates escaped so `$` in a canonical
stays literal. Deliberately single-pass over the entry list: one rule's
output is not re-matched by later rules (fixes PR #6's chained-rewrite
smell).

**Pipeline position** — applied in `DictationSession.process` to the raw
transcript BEFORE the formatter chain, so every engine (mlx/apple/cloud/
rules) sees corrected text and the LLM cannot paraphrase a term it never saw
misheard. Runs on every path including verbatim mode — corrections are about
what the user said, not how it is formatted.

**Menu** — "Add dictionary correction…" item in the menu bar: a small
two-field form (what was heard → what it should be). Adding merges into the
existing dictionary: a variant already mapped elsewhere moves to the new
canonical (case/diacritic-insensitive dedupe). Written back pretty-printed so
the file stays hand-editable.

## Error handling

Dictionary failures never lose a transcript: any load/apply error yields the
input unchanged. File writes from the menu are best-effort with a stderr
warning, same as the microphone persist.

## Testing

The replacement engine, merge/dedupe logic, and JSON round-trip are pure unit
tests (port PR #6's three regression cases as specs: literal `$`, longer-word
preservation, whole-word boundaries — plus Unicode/diacritic cases, since the
user dictates Polish names). Hot-reload and pipeline placement get seam-level
tests through `DictationSession`. The NSAlert form stays a thin shell.

## Out of scope (YAGNI)

ASR biasing/prompt tokens, per-mode vocabularies, import/export, cloud sync.
