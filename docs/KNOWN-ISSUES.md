# Known issues and deferred work

Findings from the formatting-layer review that were judged real but not
merge-blocking. Each was triaged by a whole-branch review; none is speculative.

Nothing here loses a transcript. That property was traced end to end and holds
on every path.

## Unverified, not defective

These are not bugs — they are things no automated test in this repo can reach.
`docs/MANUAL-VERIFICATION.md` is the procedure for closing them.

- **The dictation path has never run.** Audio capture, keypress, and text
  injection have no test coverage and cannot have any without a microphone and
  a human at the keyboard.
- **On-device formatting has never executed.** Apple Intelligence was disabled
  on the development machine, so every line of `FoundationModelsFormatter.format`
  past the availability guard is compile-verified only — including the
  `GenerationError` mapping and the off-cooperative-pool routing.
- **No call has ever reached `api.anthropic.com`.** The request shape is
  asserted byte-for-byte against the pinned API reference, but server
  acceptance is unconfirmed. Whether `effort: low` fits inside the chain's
  2500 ms default is also unmeasured.
- **The dual-modifier release-edge fix has never met a physical keyboard.** The
  logic is proven against flag values captured from a real device; that a
  keyboard emits those values under a two-key hold is manual step 4j–4n.

## Deferred work

- **No CLI subcommand writes the API key.** `Keychain.writePassword` exists and
  is unused; the cloud path is configurable only via `security add-generic-password`.
  Needed before anyone but the author can use it.
- **Server-side refusal fallbacks are not enabled.** The design spec calls for
  `fallbacks: "default"` with the `server-side-fallback-2026-07-01` beta header.
  Deliberately deferred: adding an unvalidated beta parameter to a request shape
  that has never been sent live compounds risk on the first real call, and a
  refusal already degrades safely to local → rules with the transcript intact.
  Revisit immediately after the first successful live call.
- **`FormatterChain.describe` interpolates non-`FormatterError` values at the
  sink.** Unreachable today — both engines translate to `FormatterError` and the
  rules floor cannot throw — but the hygiene rule is enforced per-formatter
  rather than at the sink, so a future injected formatter would reintroduce the
  leak that `CloudFormatter` and `FoundationModelsFormatter` were both hardened
  against.
- **Transcript wrapping and tag stripping are duplicated** between the two model
  formatters. The `@available(macOS 26.0, *)` rationale for duplicating does not
  hold — they are pure `String` helpers. Drift already happened once. Share them
  as an internal `TranscriptPrompt` when either file is next touched.
- **`OutputGuard`'s duplication check is substring-based**, so a short input
  recurring in a longer expansion ("thanks" → "Thanks so much… thanks again!")
  false-rejects. Fails safe to the raw transcript. A word-boundary check fixes it.
- **`sanitize()` drops parenthesised speech.** `"call me (later) today"` returns
  `"call me today"`. Pre-existing upstream behaviour, pinned by a characterization
  test rather than changed. The non-speech filter cannot distinguish `(music)`
  from real parenthesised words.
- **User-defined modes and menu-bar mode selection are documented but absent.**
  The spec describes adding modes via `config.json`; `ModeRegistry(userModes: [])`
  is hardcoded, and `MenuBarController` has no selector, so the resolver's
  `manual:` argument is always `nil`.
- **Strict-concurrency errors exist in pre-existing code** — `ModelRegistry`,
  `WhisperKitTranscriber`, `Setup`, and `HotkeyMonitor`. `HotkeyMonitor`'s
  non-`Sendable` capture from the CGEventTap callback may be a genuine
  cross-thread bug. Confirmable in about ten minutes: build with
  `-sanitize=thread`, run the daemon, and exercise the hotkey during UI updates.
  TSan either reports the race with both stacks, or reports nothing — in which
  case it is a labelling gap fixable with `@preconcurrency`.
