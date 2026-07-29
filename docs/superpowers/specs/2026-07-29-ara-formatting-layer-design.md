# Ara — Mac formatting layer

**Date:** 2026-07-29
**Status:** approved, ready for implementation planning
**Scope:** feature layer on macOS only. Rebrand, iPhone app and open-source release are separate projects.

## Context

parrot is a minimal macOS dictation daemon: hold a key, speak, release, text is injected at the cursor. It does nothing between transcription and injection. Both commercial competitors — Superwhisper and Wispr Flow — ship a formatting layer, and that is the visible gap.

This project adds cleanup, modes, custom vocabulary and history to the macOS app. It deliberately precedes the rebrand so the upstream merge path stays open while the fork is still substantially parrot.

### Constraints established by research

| Fact | Source | Consequence |
| --- | --- | --- |
| iOS keyboard extensions cap around 50 MB | WhisperBoard | Not this project, but the formatting layer must stay portable for later reuse |
| Superwhisper: on-device models, free tier, ~$8.49–9.99/mo Pro | vendor + reviews | "Free" alone is not a differentiator |
| Wispr Flow: cloud transcription, $15/mo, no lifetime | vendor | Local-only is the wedge |
| Apple `FoundationModels.framework` present in macOS 26.5 SDK | verified locally | On-device LLM with no extra download |
| `SystemLanguageModel.default.availability` → `appleIntelligenceNotEnabled` | verified locally | Apple Intelligence must be enabled; a fallback is mandatory |
| `DecodingOptions.promptTokens: [Int]?` exists | `Configurations.swift:175` | Vocabulary biasing is possible |
| Prompt budget = `(448/2)/2 - 1` = 111 tokens, kept as **suffix** | `TextDecoder.swift:339-340`, `Models.swift:1420` | Over-budget lists silently lose their *first* entries |
| `promptTokens` disables the prefill cache | `TextDecoder.swift:355` (upstream TODO) | Vocabulary costs latency on every transcription |

Measured baseline on the target machine: 2.89 s of audio → 1.33 s transcription with `whisper-base.en`. The README's "200-300 ms" claim is not accurate.

## Goals

1. Dictated speech reads like writing: filler removed, sentences repaired.
2. Output adapts to context via modes.
3. Custom vocabulary fixes the recurring proper-noun and jargon errors.
4. Past dictations are searchable and re-injectable.
5. The default install stays fully local, account-free and offline-capable.

## Non-goals

- Polish or any non-English dictation. v1 stays on `whisper-base.en`.
- Rebrand to Ara, iPhone app, open-source release.
- Streaming or partial transcription.
- Cloud as a default. It exists, opt-in only.

## Architecture

`Run.run()` is ~140 lines already handling warmup, event wiring, capture, transcription, injection and UI state. It cannot absorb four features. Extract a `DictationSession` orchestrator; `Run` keeps CLI parsing and wiring only. This refactor is in scope because the feature work depends on it. No unrelated refactoring.

Modules stay under `Sources/parrot/` — the rename is a later project.

```
Session/DictationSession.swift    pipeline orchestration
Formatting/
  Formatter.swift                 protocol: format(_:mode:) async throws -> String
  FoundationModelsFormatter.swift on-device, default engine
  CloudFormatter.swift            opt-in, key from Keychain
  RuleBasedFormatter.swift        terminal fallback, cannot fail
  FormatterChain.swift            engine selection, deadline, fallback
Modes/
  Mode.swift                      id, name, prompt, appBundleIDs, usesLLM
  ModeRegistry.swift              built-ins + user-defined
  ModeResolver.swift              flag > menu selection > frontmost app > default
Vocabulary/
  Vocabulary.swift                load, save, ordering
  VocabularyBias.swift            tokenize, trim to 111, warn on truncation
History/
  TranscriptStore.swift           JSONL append, search, retention
Config/
  Config.swift                    load, merge with CLI flags
```

### Data flow

```
key press    → AudioCapture.start
key release  → samples
             → Transcriber.transcribe(samples, promptTokens: vocabulary?)
             → raw text
             → ModeResolver.current()
             → FormatterChain.format(raw, mode)        [deadline 2.5s]
             → TextInjector.inject(clean)
             → TranscriptStore.append(record)
```

## Formatting engine

Engine is configured; every path terminates in rules, which cannot fail.

```
engine: "local"  (default) → FoundationModels → rules
engine: "cloud"            → Cloud → FoundationModels → rules
engine: "rules"            → rules
engine: "off"              → inject raw
```

Cloud never activates implicitly. A default install performs no network I/O.

### Two invariants

1. **Never lose the transcript.** Any formatting failure — unavailable model, network error, timeout, nonsense output — injects the raw text instead. Formatting is an enhancement, never a dependency.
2. **Verbatim mode skips the LLM.** It is the fast path at baseline latency, not a degraded mode.

### Deadline

Every formatting call runs under a 2.5 s deadline (configurable). On expiry the LLM result is abandoned and raw text is injected. A dictation tool that stalls is worse than one that is occasionally unpolished.

### Prompt-injection and instruction-following guard

Instruction-tuned models answer text instead of rewriting it: dictating "what's the capital of France" can return "Paris". Two defences:

1. Instructions frame the task as rewrite-only, with the transcript fenced as data rather than instruction.
2. A length-ratio sanity check. If the output length deviates from the input beyond a threshold, discard it and inject raw.

This is the most likely everyday failure and must be covered by tests.

## Modes

```swift
struct Mode {
    let id: String
    let name: String
    let prompt: String
    let appBundleIDs: [String]
    let usesLLM: Bool
}
```

Built-ins:

| id | behaviour |
| --- | --- |
| `verbatim` | no LLM, rule cleanup only |
| `default` | strip filler, repair sentence boundaries, preserve wording |
| `email` | paragraphs, greeting-aware, polished |
| `chat` | terse, no pleasantries |
| `code` | preserve identifiers, do not prose-ify |

Users define additional modes in `config.json` with the same shape; no code change required.

Resolution order: `--mode` flag → menu-bar selection → frontmost app bundle ID via `NSWorkspace.shared.frontmostApplication` → `default`. The daemon runs as `.accessory`, so it never steals focus and the frontmost app is always the real target.

## Vocabulary

`~/.config/ara/vocabulary.txt`, one term per line. Applied at two points:

1. **Decoder bias.** Tokenized and passed as `promptTokens`. Trimmed explicitly to 111 tokens with a warning naming the dropped terms — WhisperKit would otherwise keep the suffix and silently drop the earliest entries.
2. **Post-hoc correction.** The same terms are supplied to the formatter prompt for spelling fixes. No latency cost, catches what biasing missed.

**Empty by default.** A non-empty vocabulary sets `promptTokens`, which disables WhisperKit's prefill cache and slows every transcription. Users opt into that tradeoff knowingly; the default install keeps baseline latency.

## History

JSONL appended to `~/Library/Application Support/Ara/history.jsonl`. One record per dictation:

```json
{"ts":"...","mode":"email","raw":"...","clean":"...",
 "durationSec":2.89,"rms":0.002,"transcribeMs":1330,
 "formatMs":420,"engine":"foundationModels","app":"com.apple.mail"}
```

Linear scan for search. At personal volume this stays fast for years and avoids an SQLite dependency for a feature that does not need one.

**Privacy.** This writes everything ever dictated to disk in plaintext, permanently. Passwords, keys and third-party personal information will end up there. For a tool whose pitch is that nothing leaves the machine, an unbounded log is where that promise rots. Therefore: retention defaults to 30 days, `parrot history --clear` wipes it, `history.enabled: false` disables it entirely.

CLI: `parrot history` (recent), `--search <term>`, `--last`, `--clear`. The binary is still `parrot` in this project; the rename is a later one.

**On-disk paths use the `ara` name deliberately**, ahead of the rename, so the rebrand does not require a config-and-history migration later. The binary name and the paths diverge for one project; that is the cheaper of the two inconsistencies.

## Config

`~/.config/ara/config.json`. Precedence: CLI flags > config > defaults.

```json
{
  "hotkey": "right-command",
  "model": "whisper-base.en",
  "engine": "local",
  "timeoutMs": 2500,
  "mode": "default",
  "history": {"enabled": true, "retainDays": 30},
  "cloud": {"provider": "anthropic", "model": "claude-opus-5",
            "keychainAccount": "ara-cloud"},
  "modes": []
}
```

The cloud API key lives in the Keychain, never in the file — this repository is headed for public release.

### Cloud path specifics

Pinned from the `claude-api` reference rather than memory:

- **Model `claude-opus-5`** ($5/$25 per MTok, 1M context).
- **`thinking: {"type": "adaptive"}` with `output_config: {"effort": "low"}`.** Thinking is *on by default* on this model. Do **not** set `{"type": "disabled"}`: disabled thinking on Opus 5 can emit `<thinking>` tags into the visible response, and this app types the visible response straight into the user's cursor. Low effort is the latency lever; disabling thinking is not.
- **No SDK.** Anthropic ships no official Swift SDK, so the cloud formatter is raw HTTPS against `POST /v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`.
- **Handle `stop_reason: "refusal"` before reading `content`.** Safety classifiers return HTTP 200 with an empty or partial `content` array. Dictated speech can occasionally trip them. This routes into the existing raw-text fallback — never index `content[0]` unguarded.
- **Opt into `fallbacks: "default"`** (beta header `server-side-fallback-2026-07-01`) so a declined request is re-served rather than lost.
- **Structured output** via `output_config.format` returning `{"cleaned": string}`. This doubles as the rewrite-only guard: a schema-constrained response cannot become a chat answer.
- **Prompt caching will not engage.** The minimum cacheable prefix on Opus 5 is 512 tokens; mode prompts are far shorter. Do not add `cache_control` — it would only pay the write premium.

## Error handling

| Failure | Behaviour |
| --- | --- |
| Apple Intelligence disabled | fall through to next engine; surface once in `doctor` |
| Cloud key missing or request fails | fall through to local, then rules |
| Cloud returns `stop_reason: "refusal"` | treat as failure, inject raw; never read `content[0]` unguarded |
| Formatting exceeds deadline | abandon, inject raw |
| Output fails length-ratio guard | discard, inject raw |
| Vocabulary over budget | trim, warn, name dropped terms |
| History write fails | log, never block injection |

Nothing in this table prevents text from reaching the cursor.

## Testing

The repository currently has **zero tests**; a test target is added as part of this work. The fallback chain is precisely the logic that fails silently without one.

Unit tested:
- `RuleBasedFormatter` cleanup
- `FormatterChain` fallback ordering, using stub formatters that throw and that exceed the deadline
- Length-ratio guard, including the "capital of France" case
- `ModeResolver` given bundle id plus override
- Vocabulary tokenization and the 111-token trim, asserting *which* terms survive
- `TranscriptStore` append, search, retention pruning
- `WhisperKitTranscriber.sanitize()` — pure, currently untested

Not unit testable, covered by a written manual checklist: audio capture, event tap, text injection, real LLM output quality.

## Risks

| Risk | Mitigation |
| --- | --- |
| Added latency makes dictation feel slow | deadline, verbatim fast path, `formatMs` recorded in history for measurement |
| On-device model quality disappoints | cloud opt-in exists; rules floor is always available |
| Apple Intelligence requirement narrows the audience | rules fallback keeps the app functional for everyone |
| History becomes a privacy liability | retention, clear command, opt-out |
| Fork diverges from upstream | rebrand deliberately deferred; changes kept reviewable for upstreaming |
