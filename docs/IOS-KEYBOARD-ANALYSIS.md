# Ara in an iOS keyboard — engineering analysis

Researched 2026-07-30. Platform claims carry citations; anything unverified says so.

## The sentence that reorganises the problem

The two products are blocked on **opposite** things, and neither block moves the other.

- **Cleanup of typed text** (the Grammarly replacement): the text is already reachable
  inside the extension via `UITextDocumentProxy`. No microphone, no app switch. Blocked
  entirely on **running inference inside a ~30–48 MB extension process**.
- **Dictation**: inference is easy — it happens in the containing app with a full app
  memory budget running Ara's real MLX stack. Blocked entirely on **the microphone being
  unavailable to keyboard extensions**, forcing an app-switch UX that iOS 26.4 made worse.

One has the UX and needs an engine; the other has the engine and needs a UX. Do not design
them as one thing.

## Hard platform facts

**Microphone: impossible, settled.** Not policy — entitlement-enforced at the media daemon.
Apple's archived keyboard guide: custom keyboards "have no access to the device microphone,
so dictation input is not possible." Runtime proof with Full Access on:
`CMSUtility_IsAllowedToStartRecording: … NOT allowed … because it is an extension`.
`NSMicrophoneUsageDescription` in a keyboard's Info.plist is inert.
**Note: the existing YapperX keyboard doc plans `AVAudioEngine` inside the extension. That
will fail on device.** (No keyboard target was ever created, so nothing is lost.)

**Memory: no documented number, ever.** Apple says only that limits "vary from model to
model". Developer-sourced figures: 48 MB commonly cited; ~30–40 MB dirty from someone who
worked on SwiftKey iOS. At the limit jetsam kills the extension, the keyboard vanishes, and
**you often get no crash report at all**. Use `os_proc_available_memory()` rather than
hardcoding. The process persists across invocations, so retained state kills you three apps
later, not where you allocated it.

**A real LLM in the extension: dead.** MLX carries ~110 MB fixed overhead above weights.
Qwen2.5-1.5B-4bit (Ara's shipped model) peaks ~1.0 GB. Even a 135M model lands ~250 MB —
5× over budget before a single activation. No App Store keyboard is known to do this.

**Foundation Models is the exception — and the whole ballgame.** Apple engineer: the model
and inference resources are "managed centrally by the operating system", so app memory
increase is "very minimal" — measured ~27 MB charged in-process for a 3B model. That fits.
**But it is gated per extension type and keyboards are untested**: confirmed working in
Safari extensions, confirmed blocked as-designed in DeviceActivityReport (sandbox error 159)
and MessageFilter, **zero evidence either way for `com.apple.keyboard-service`**.

**App Review 4.4.1 is an architectural constraint**: a keyboard must "remain functional
without full network access and without requiring full access". Your QWERTY must work
offline with the toggle off. Everything Ara adds is strictly additive. Also 4.4: **no IAP
or paywall UI inside the extension** — it lives in the container app.

**iOS 27 beta adds grammar checking to `UITextChecker`**
(`requestGrammarChecking(of:range:...)`, no documentation text yet). It could obsolete the
LLM layer — or become its free floor. Watch it.

## What ports from Ara

Every macOS-only file is in the "get text in and out of the world" layer. **The entire
cleanup engine is portable.** That is why this is worth doing.

Compiles for iOS unchanged: `FormatterChain` (the deadline/fallback/never-lose-the-input
contract — worth more on a keyboard, where a wedged model means a frozen keyboard),
`OutputGuard`, `RuleBasedFormatter`, `CleanupIntensity`, `LocalDictionary`, `Snippets`,
`DictationSession`, `Pipeline`, `TranscriptLog`, and all six `*MenuModel` types (reusable as
SwiftUI settings models).

Needs a shim: `FoundationModelsFormatter` (add `iOS 26.0`), `CloudFormatter`, `Keychain`
(access group), `MLXFormatter` (container app only; MLX needs iOS 26 and **does not run in
the simulator**).

**Blocker to fix regardless**: `Hotkey`/`InjectionPolicy` import ArgumentParser *inside the
library*, so `AraCore` cannot be an iOS library today. Move those conformances to the
executable target. This is a latent design bug on macOS too.

**The trap**: `TranscriptPrompt` is a *dictation* prompt — every variant opens "You are a
copy editor for dictated speech", removes filler words, and converts spoken "comma" into
marks. All wrong for typed text. What transfers is the *measured ordering discipline*
(task first, examples middle, safety as an aside, tag-leak guard last) and the four-family
injection few-shot set — which matters more on a keyboard, since it sees text the user did
not author. Split into `.dictation` (frozen, measured) and `.typed` (new, unmeasured until
`scripts/cleanup-eval` is re-run). `OutputGuard`'s 0.4–4.0 ratio was tuned for dictation;
typed text should land near 1.0.

## Recommended path

**1. Run the one-hour spike first.** Empty keyboard extension, `RequestsOpenAccess = YES`,
physical A17 Pro+ device with Apple Intelligence on, one button calling
`SystemLanguageModel.default.availability` then a `LanguageModelSession` response. Run it
with Full Access **on and off**, and **on battery**. Record `.available`, sandbox error 159,
or `.rateLimited`. While there, call `AVAudioEngine.start()` with an `inputNode` and confirm
the recording refusal. That hour has more decision value than the next two weeks of code.

**2. Extract `AraText`** — Foundation-only, both platforms: Formatting, Modes, Vocabulary,
Session, Config, plus new `ConfigLocation` (App Group container on iOS) and `LogSink`
(stderr goes nowhere from an extension). Keep the JSON byte-format identical so a dictionary
written on the Mac drops straight into the iPhone. Pays for itself on macOS regardless.

**3. Ship the deterministic keyboard — no model at all.** `LocalDictionary` + `Snippets` +
`RuleBasedFormatter` + `UITextChecker`. Works with **Full Access off**, on **every device**,
no Apple Intelligence, no region gate, single-digit MB, collects nothing → **empty privacy
nutrition label**. That claim is unavailable to Grammarly, whose own support page says the
keyboard needs full access to reach the internet. 1–2 weeks with KeyboardKit; 4–6 from
scratch.

**4. Add `.apple` only if the spike passed**, behind `FoundationModelsFormatter.isAvailable`,
with retuned guard bounds and the eval harness re-run with FM as a column. Ara's own
KNOWN-ISSUES is explicit that the FoundationModels path has never executed and its numbers
"do not automatically transfer".

**5a. Dictation v1 is nearly free — and this is the best effort:value ratio in the
analysis.** On Face ID iPhones, iOS draws **its own dictation button** over a third-party
keyboard *unless* you set `hasDictationKey = true`. So: don't set it. Apple provides the
microphone, the ASR, the permission prompt and the privileged audio path at zero
engineering cost, dictated text arrives via `UITextInputDelegate` — and then you run it
through Ara's cleanup chain. **Apple's dictation is already good at transcription and bad
at cleanup; Ara is a cleanup engine.** That is ~90% of the Ara experience for ~0% of the
audio engineering, on every device, with no Full Access and no app hop. **2–3 days.**
Known wrinkle: a developer reports the final `textDidChange` lowercases dictated text on
acceptance — Ara's capitalisation rules mask it anyway.

**5b. Dictation v2 — the containing-app recorder — only if v1's ceiling proves real.** on the container-app architecture, using
`SpeechAnalyzer` rather than WhisperKit (runs outside your address space — zero app-size and
zero runtime-memory cost). Accept the app-hop: Grammarly and Wispr Flow both ship it, and
both document that **iOS 26 removed the automatic return** — the user must swipe back
manually. DTS confirmed with App Review that launching *your own container app* from a
keyboard is allowed; sending the user back has "no API available".

## UX facts to prototype before writing engine code

- You cannot draw squiggles in the host text view — a keyboard renders only its own frame.
  The affordance is a suggestion bar.
- Replacing text is N × `deleteBackward()` then `insertText()`. There is no ranged replace.
- **Measure `documentContextBeforeInput` truncation in hour one** — it bounds the product.
- Free dictation button: on Face ID iPhones iOS draws the system dictation key over your
  keyboard unless you set `hasDictationKey = true`. Apple's privileged path, zero effort.

## Biggest unknowns

Foundation Models reachability from a keyboard sandbox (the spike). Any Apple-published
extension memory number (none exists). Whether the increased-memory-limit entitlement
affects an appex. `documentContextBeforeInput` behaviour across hosts.

## Three traps specific to this port

**The cooperative pool is 2–6 threads wide on an iPhone, not 12.** `FormatterChain`'s doc
comment measures orphaned blocking work stalling calls by ~9.16 s once orphan count reached
pool width — on a Mac that was call 12. On a phone it arrives at call 2 or 3. In a 30 MB
extension an orphaned task holding allocations is also a jetsam vector. `runOffCooperativePool`
becomes stricter, not optional.

**Text replacement is where keyboard projects actually die.** `UITextDocumentProxy` has no
ranged replace and no whole-document read: rewriting a 200-character paragraph means 200
`deleteBackward()` calls across an IPC boundary, then `insertText`. Compute a **minimal
diff** and apply only the changed suffix; cap scope at the current sentence. And note what
this does to an existing invariant — `Formatter`'s "never return empty for non-empty input"
stops being politeness and becomes a **data-loss guard**: an empty return after 200
deletions has erased the user's paragraph. Assert before deleting.

**Secure fields never reach you.** `isSecureTextEntry` and phone-pad fields always fall back
to the system keyboard. Legally excellent; means you cannot promise "works everywhere".

## Effort, solo

| Work | Estimate |
|---|---|
| The Foundation-Models-in-an-appex spike | **1 day, do it first** |
| `AraCore` → `AraEngine` + `AraMacOS` refactor (de-ArgumentParser, store/log seams) | 3–5 days |
| Architecture C slice 1 — deterministic keyboard, no ML | 2–3 weeks |
| Slice 2 — Foundation Models engine, conditional on the spike | 1 week |
| Polish to submittable (memory instrumentation, host matrix, IAP, manifests) | 1–2 weeks |
| **Dictation v1 — free system mic + Ara cleanup** | **2–3 days** |
| Dictation v2 — containing-app recorder, background audio survival | 4–6 weeks, high risk |

**~5–7 weeks to a submittable Grammarly replacement**, of which the first four days are a
refactor and one spike that could invalidate the plan.
