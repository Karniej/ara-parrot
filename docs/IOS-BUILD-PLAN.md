# Ara for iOS — build plan

Written 2026-08-07. Reads on top of `IOS-KEYBOARD-ANALYSIS.md`, which holds the platform
research; this document is the sequencing, the product decisions and the money.

**Product in one sentence:** a keyboard that dictates and cleans up your writing entirely on
your device, sold once, that collects nothing — and can prove it.

---

## Why this is a product and not a feature

Wispr Flow and Grammarly both have better funding, better ASR and a head start. Neither can
say the sentence above:

- **Wispr Flow** streams your audio to a server. Subscription.
- **Grammarly** requires Full Access to reach the internet, by its own support documentation.
  Subscription.

Everything either company does well requires sending your keystrokes or your voice somewhere.
The wedge is not "better cleanup" — it is **an empty privacy nutrition label on the App Store
page**, which is a claim a competitor cannot answer without rebuilding their business.

The second wedge is price. A one-time purchase against two subscriptions is a straight
comparison a buyer can make in five seconds, and it is the honest model for software that
has no server bill to pay.

**The competitive risk is Apple, not Grammarly.** iOS 27 beta adds grammar checking to
`UITextChecker`. If Apple ships good on-device cleanup system-wide, the smart tier's value
collapses. Build so that the deterministic layer stands alone (see Phase 2) and treat the
model tier as upside.

---

## Phase 0 — the spike. One day. Do not skip it.

Three experiments in one throwaway keyboard extension, on a **physical A17 Pro or newer**,
each run with Full Access **on and off** and **on battery**. Full detail in the analysis
document; the decision table is here.

| # | Experiment | If it passes | If it fails |
|---|---|---|---|
| 1 | Foundation Models from the appex | Smart cleanup tier exists | Ship deterministic-only; revisit at iOS 27 |
| 2 | `AVAudioEngine` recording in the appex | Own mic button, own recording UI | Fall back to Apple's system dictation key (5a) |
| 3 | **`SpeechAnalyzer` on-device ASR from the appex**, instrumented with `os_proc_available_memory()` | **The product exists as pitched** | No local dictation in-keyboard — 5a or bust |

**Experiment 3 is the one that decides everything.** Recording is cheap; recognition is not.
If on-device ASR cannot run out-of-process from a keyboard sandbox within the memory budget,
then in-keyboard dictation requires a server, and the product's entire premise is gone. Find
that out on day one, not in week five.

**Results, 2026-08-07 — iPhone 11 (A13), iOS 26.0, Full Access on:**

| # | Result |
|---|---|
| 1 | `deviceNotEligible` — hardware verdict only; re-run on an A17 Pro+ (arriving ~2026-08-14) answers the sandbox question |
| 2 | **FAILED comprehensively** — permission granted, mic visible, all four capture paths refused (`kAUStartIO` → `'what'`; `AVAudioRecorder.record()` → false). In-appex recording is off the table. |
| 3 | **PASSED ×6** — on-device `SFSpeechRecognizer`, 412–810 ms, ~0 MB charged to the appex (out-of-process). **The product exists without a server.** |
| 4 | **PASSED** — container app kept recording while backgrounded with the keyboard frontmost: +144,000 frames / 3 s = exactly 48 kHz, no gaps, heartbeat 0.4 s over the App Group. **The container relay is the Phase 3 architecture.** |

Consequence for Phase 3: the **container relay** is measured real — the app records in
the background (UIBackgroundModes audio) while the keyboard fronts the UI, and the App
Group carries audio-derived state to the keyboard. This is Wispr Flow's shape, reproduced.
Its two boundaries: the keyboard cannot cold-start the app (the wake channel —
Live Activity / `LiveActivityIntent` — is spike **experiment 5**, still to run), and the
keyboard's App Group read needs Full Access, so the relay is a Full-Access feature; the
system dictation key remains the no-Full-Access fallback tier. Still outstanding:
Full Access off pass, control-group run, and the A17 re-run of experiment 1.

---

## Phase 1 — extract `AraEngine`. 3–5 days.

A Foundation-only library both platforms share. Pays for itself on macOS regardless of
whether the iOS product ever ships.

**Moves in unchanged:** `FormatterChain`, `OutputGuard`, `RuleBasedFormatter`,
`CleanupIntensity`, `LocalDictionary`, `Snippets`, `DictationSession`, `Pipeline`,
`EmptyDictation`, `FormatterDeadline`, and the `*MenuModel` types (they become SwiftUI
settings models).

**Must be fixed to make it compile for iOS:** `Hotkey` and `InjectionPolicy` import
ArgumentParser *inside the library*, so `AraCore` cannot be an iOS target today. Move those
conformances to the executable. This is a latent design bug on macOS too.

**New seams:** `ConfigLocation` (App Group container on iOS, `~/.config/ara` on macOS) and
`LogSink` (stderr goes nowhere from an extension).

**Keep the JSON byte-format identical.** A dictionary edited on the Mac must drop straight
into the phone. That is a feature worth advertising, and it is free if the format does not
drift.

**Split `TranscriptPrompt` into `.dictation` and `.typed`.** Every existing prompt variant
opens "You are a copy editor for dictated speech" and strips filler words — all wrong for
text the user typed. The measured ordering discipline transfers; the wording does not.
`OutputGuard`'s 0.4–4.0 ratio was tuned for dictation and should land near 1.0 for typed
text. Re-run `scripts/cleanup-eval` before trusting either.

---

## Phase 2 — the deterministic keyboard. 2–3 weeks.

**Ship this before any model, and make it good enough to sell on its own.**

`LocalDictionary` + `Snippets` + `RuleBasedFormatter` + `UITextChecker`. No ML anywhere.

Why this order: it works with **Full Access off**, on **every device**, with no Apple
Intelligence and no region gate, in single-digit megabytes, and it collects nothing. That is
the empty privacy label — earned in phase 2, not promised in phase 5. It is also the
insurance policy against Apple shipping system-wide grammar cleanup.

**The hard part is not the cleanup. It is text replacement.** `UITextDocumentProxy` has no
ranged replace and no whole-document read. Rewriting a 200-character paragraph means 200
`deleteBackward()` calls across an IPC boundary, then `insertText`. So:

- Compute a **minimal diff** and apply only the changed suffix.
- **Cap scope at the current sentence.** Never rewrite what the user cannot see.
- `Formatter`'s "never return empty for non-empty input" stops being politeness and becomes a
  **data-loss guard**: an empty return after 200 deletions has erased the user's paragraph.
  Assert before deleting, not after.

**Measure `documentContextBeforeInput` truncation in hour one.** It bounds the entire
product, and it varies by host app.

**Also true and worth designing around:** you cannot draw squiggles in the host text view —
a keyboard renders only its own frame, so the affordance is a suggestion bar. Secure fields
(`isSecureTextEntry`, phone pads) always fall back to the system keyboard, so "works
everywhere" is not a claim you can make.

---

## Phase 3 — dictation. Two tiers, both measured viable (spike results above).

**Tier A — the container relay (Full Access, the flagship UX):** the app records in the
background (`UIBackgroundModes: audio`), on-device ASR transcribes, `AraEngine` cleans up,
the App Group carries the transcript, the keyboard's own mic button and recording animation
front the whole thing. Wispr Flow's UX with none of its cloud — **measured working
2026-08-07** (48 kHz sustained while backgrounded). Open engineering questions, in order:
the wake channel when the app isn't running (experiment 5 — Live Activity /
`LiveActivityIntent`; the honest fallback is "open the app once after reboot"), how long
iOS lets the session live, and the always-on-mic privacy story (the orange indicator is
permanent while armed — this must be a deliberate, user-visible mode, not a surprise).

**Tier B — the system dictation key (free tier, no Full Access):** don't set
`hasDictationKey`; iOS draws its own dictation button over the keyboard. Apple supplies
mic, ASR, permission prompt and the privileged audio path; text arrives via
`UITextInputDelegate` and `AraEngine` cleans it up. 2–3 days, every device.

Ship B first inside Phase 2's keyboard, then build A on top. The cleanup chain is the same
code either way, which is the point of Phase 1. The *foreground* app-hop recorder (switch
to app, talk, switch back) stays dead — iOS 26 removed the automatic return and the relay
makes it pointless.

---

## Phase 4 — the model tier. 1 week. Only if experiment 1 passed.

Foundation Models behind `FoundationModelsFormatter.isAvailable`, as one more engine in the
existing chain — which already knows how to fall through to the rules floor when an engine is
unavailable, slow or implausible. Retune the guard bounds for typed text and re-run the eval
harness with FM as a column.

Ara's own `KNOWN-ISSUES.md` is explicit that the FoundationModels path has never executed and
its numbers do not automatically transfer. Treat every published figure as unmeasured until
the harness says otherwise.

---

## Phase 5 — polish to submittable. 1–2 weeks.

Memory instrumentation on every path (`os_proc_available_memory()`, not hardcoded limits);
a host-app matrix (Messages, Mail, Safari, Notes, Slack, X) because `documentContextBeforeInput`
behaviour differs; onboarding that explains the two Settings toggles without sounding like a
permission grab; App Store privacy manifests.

**The cooperative pool is 2–6 threads wide on an iPhone, not 12.** `FormatterChain`'s
measured stall from orphaned blocking work arrived at call 12 on a Mac; on a phone it arrives
at call 2 or 3. In a 30 MB extension an orphaned task holding allocations is also a jetsam
vector — and jetsam kills the keyboard with **no crash report**. `runOffCooperativePool`
becomes stricter, not optional. The `.busy` refusal shipped in macOS 0.1.1 matters more here
than it does there.

---

## Money

**One-time purchase.** No subscription, no server, no ongoing cost to fund.

Two constraints from App Review, both architectural rather than cosmetic:

- **4.4: no IAP or paywall UI inside the extension.** Purchase lives in the container app.
  The keyboard reads entitlement from the App Group; it never presents a price.
- **4.4.1: the keyboard must remain functional without Full Access and without network.**
  The free tier is therefore a *real* keyboard, and everything Ara adds is strictly additive.

Suggested shape: free tier is the QWERTY plus dictionary and snippets; the purchase unlocks
cleanup, intensity control and dictation polish. RevenueCat handles the receipt so a
reinstall or a second device restores without an account — which keeps the empty privacy
label intact.

**Do not add an account.** The moment there is a login there is a user record, and the
privacy claim becomes a paragraph instead of a label.

---

## Honest risks

1. **Experiment 3 fails** and on-device ASR cannot run from the appex. The product becomes
   "Apple's dictation, cleaned up" — still good, materially less differentiated. *Highest
   impact, unknown probability, one day to find out.*
2. **Apple ships system-wide grammar cleanup in iOS 27.** The smart tier's value collapses.
   Mitigated by Phase 2 standing alone.
3. **Memory kills you three apps later.** The extension process persists across invocations,
   so retained state jetsams somewhere unrelated to where it was allocated, with no crash
   report. Instrument from day one, not at the end.
4. **Text replacement is where keyboard projects actually die.** Not the ML. Budget real time
   for the diff-and-replace layer and treat it as the core engineering, because it is.
5. **The privacy claim must survive a lawyer reading it.** Any analytics SDK, any crash
   reporter that phones home, any "anonymous" telemetry, and the label is no longer empty.
   Decide this once, at the start, and hold it.

---

## Sequence, compressed

```
Day 1        Phase 0 spike ......................... decides everything below
Days 2–6     AraEngine extraction .................. also improves macOS
Weeks 2–4    Deterministic keyboard ................ shippable on its own
+2–3 days    Dictation (route per spike) ........... the visible feature
+1 week      Model tier (only if experiment 1 passed)
+1–2 weeks   Polish, host matrix, privacy manifest, purchase
```

**~5–7 weeks solo to submittable**, of which day one can invalidate the plan — which is the
entire reason it is day one.
