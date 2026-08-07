# Ara in an iOS keyboard — engineering analysis

Researched 2026-07-30. **Corrected 2026-08-07** — the microphone section was wrong and is
marked where it was. Platform claims carry citations; anything unverified says so. A claim
sourced to an *archived* Apple document is not settled fact, which is the lesson that
correction bought.

## The sentence that reorganises the problem

The two products are blocked on **opposite** things, and neither block moves the other.

- **Cleanup of typed text** (the Grammarly replacement): the text is already reachable
  inside the extension via `UITextDocumentProxy`. No microphone, no app switch. Blocked
  entirely on **running inference inside a ~30–48 MB extension process**.
- **Dictation**: inference is easy *in the containing app* — full memory budget, Ara's real
  MLX stack. Blocked on getting **audio and recognition** to happen where the keyboard is.
  As of 2026-08-07 the microphone half looks **open, not closed** (see Hard platform facts);
  the recognition half is bounded by extension memory, so it turns on whether on-device ASR
  can run out-of-process from an appex.

One has the UX and needs an engine; the other has the engine and needs a UX. Do not design
them as one thing.

## Hard platform facts

**Microphone: OPEN QUESTION — this section was wrong.** ⚠️ Corrected 2026-08-07.

The original claim was "impossible, settled", resting on Apple's *archived* custom-keyboard
guide (that text dates to the iOS 8 era) and a runtime error string —
`CMSUtility_IsAllowedToStartRecording: … NOT allowed … because it is an extension` — whose
date and provenance were never established and which was never reproduced on a device for
this project. It was presented as settled fact. It is not.

**Contradicting field observation (2026-08-07, Wispr Flow on iOS, direct):** its keyboard is
its own, not Apple's; tapping *its* microphone button raises *its own* permission prompt,
shows *its own* recording animation, and inserts text into the active field **with no app
switch**. Full Access is required. Apple's system dictation key does not behave that way —
it would raise Apple's prompt and draw Apple's UI.

**MEASURED 2026-08-07 (iPhone 11, iOS 26.0, Full Access on): in-appex recording is
dead — comprehensively.** Permission granted, `MicrophoneBuiltIn` visible, and every
capture path refused: `AVAudioEngine` under `.record`, `.playAndRecord/.mixWithOthers`
and `.voiceChat` all failed at `kAUStartIO` with `'what'`
(AVAudioSessionErrorCodeUnspecified), and `AVAudioRecorder.record()` returned false.
That is `mediaserverd` policy, exactly as the archived guide said — the original claim
was right, and the Wispr Flow observation has a different explanation: their *container
app* records in the background (UIBackgroundModes audio) while their keyboard fronts the
UI and relays through the App Group. That theory was spike experiment 4 — and it is now
**MEASURED TRUE (2026-08-07, iPhone 11, iOS 26.0, build 8):** with the app backgrounded
and the keyboard on screen, the app's `AVAudioEngine` tap kept delivering **+144,000
frames over 3 s — exactly 48 kHz, zero gaps** — heartbeat fresh at 0.4 s, relayed through
`group.com.silpho.araspike`. The container-relay architecture is real and is the basis
for Phase 3. Two caveats bound it: the app must have been launched (a keyboard cannot
cold-start its container app — the wake channel is the Live Activity / `LiveActivityIntent`
question, spike experiment 5), and the App Group read from the keyboard requires **Full
Access**, so the relay is a Full-Access feature by construction.

**Also measured, and the product-deciding result: on-device ASR WORKS from the appex.**
`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, three runs, 415–477 ms
for a bundled sentence, memory charged to the extension ≈ 0 (65→65 MB) — recognition
runs out-of-process in the speech daemon. Appex headroom measured at 67–72 MB, better
than the 30–48 MB folklore. Experiment 1 reported `deviceNotEligible` — that is the
iPhone 11's A13 speaking, not the sandbox; the eligible-hardware answer waits for an
A17 Pro+ device.

**What did not change: memory.** Recording is cheap — a few MB of buffers. Transcribing is
not. The section below still rules out a local Whisper or a local LLM inside a ~30–48 MB
extension, so permission to record does not by itself buy on-device dictation. Wispr Flow
is a **cloud** product: recording in the extension and streaming audio to a server fits
every observation above, including why it needs Full Access. That route is closed to Ara by
the product's own premise, not by the platform.

**The question that now decides the iOS product** is therefore not "can we record?" but
**"can on-device speech recognition run from an extension without being charged its
memory?"** `SpeechAnalyzer` / `SFSpeechRecognizer` run in a system daemon out of the app's
address space — the same architecture that makes Foundation Models viable at ~27 MB
charged. If that holds inside a keyboard sandbox, Ara gets Wispr Flow's UX with none of its
cloud. See experiment 3.

**Note: the existing YapperX keyboard doc plans `AVAudioEngine` inside the extension.** That
may well be fine — verify with experiment 2 before acting on either doc.

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

**1. Run the one-day spike first — three experiments, one throwaway extension.** Empty
keyboard extension, `RequestsOpenAccess = YES`, physical A17 Pro+ device with Apple
Intelligence on. Run every experiment with Full Access **on and off**, and **on battery**.

  1. **Foundation Models**: `SystemLanguageModel.default.availability`, then a real
     `LanguageModelSession` response. Record `.available`, sandbox error 159, or
     `.rateLimited`. Decides whether the smart cleanup tier exists.
  2. **Microphone**: `AVAudioEngine.start()` with an `inputNode`, and whether the permission
     prompt appears. The previous version of this document asserted this fails; a shipping
     competitor suggests otherwise. Decides the whole dictation UX.
  3. **On-device ASR, and the one that matters most**: `SpeechAnalyzer` (or
     `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`) transcribing from
     inside the appex, instrumented with `os_proc_available_memory()` before, during and
     after. Decides whether Ara-on-iOS is possible **without a server**.

That day has more decision value than the next two weeks of code. Experiment 3 gates the
product; 2 gates its UX; 1 gates its polish.

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

**5a. Dictation v1 — the free system key — is still the cheapest start.** On Face ID
iPhones, iOS draws **its own dictation button** over a third-party keyboard *unless* you set
`hasDictationKey = true`. So: don't set it. Apple provides the microphone, the ASR, the
permission prompt and the privileged audio path at zero engineering cost; dictated text
arrives via `UITextInputDelegate` and you run it through Ara's cleanup chain. **Apple's
dictation is already good at transcription and bad at cleanup; Ara is a cleanup engine.**
~90% of the Ara experience for ~0% of the audio engineering, on every device, with no Full
Access. **2–3 days.** Known wrinkle: a developer reports the final `textDidChange`
lowercases dictated text on acceptance — Ara's capitalisation rules mask it anyway.

Its ceiling is real, though: you get Apple's ASR, Apple's languages, Apple's UI, and no
control over endpointing or the recording affordance. It is the fastest way to a shipped
product, not the best product.

**5b. Dictation v2 — own microphone, own recording UI, in the extension.** What Wispr Flow
appears to do, minus the server. Gated on spike experiments 2 and 3 together: record with
`AVAudioEngine` in the appex, recognise with `SpeechAnalyzer` out-of-process, insert the
result. If both pass, this is the product — Wispr Flow's UX with an empty privacy label.
If 3 fails on memory, fall back to 5a rather than to a server.

**5c. Dictation v3 — the containing-app recorder — only if both above fail.** Accept the
app-hop: Grammarly and Wispr Flow's earlier design both shipped it, and iOS 26 removed the
automatic return, so the user must swipe back manually. DTS confirmed with App Review that
launching *your own container app* from a keyboard is allowed; sending the user back has
"no API available". Worst UX of the three; keep it as the floor, not the plan.

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
| The three-experiment spike (Foundation Models, microphone, on-device ASR) | **1 day, do it first** |
| `AraCore` → `AraEngine` + `AraMacOS` refactor (de-ArgumentParser, store/log seams) | 3–5 days |
| Architecture C slice 1 — deterministic keyboard, no ML | 2–3 weeks |
| Slice 2 — Foundation Models engine, conditional on the spike | 1 week |
| Polish to submittable (memory instrumentation, host matrix, IAP, manifests) | 1–2 weeks |
| **Dictation v1 — free system mic + Ara cleanup** | **2–3 days** |
| Dictation v2 — own mic in the appex + on-device ASR (needs experiments 2+3) | 1–2 weeks |
| Dictation v3 — containing-app recorder, app-hop fallback | 4–6 weeks, high risk |

**~5–7 weeks to a submittable Grammarly replacement**, of which the first four days are a
refactor and one spike that could invalidate the plan.
