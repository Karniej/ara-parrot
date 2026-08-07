# Ara for iOS — product & app design

Written 2026-08-07, after the Phase 0 spike completed. This is the design the
implementation follows; `IOS-BUILD-PLAN.md` holds the phasing and money rationale,
`IOS-KEYBOARD-ANALYSIS.md` the platform measurements. Where this document and the build
plan disagree, this document wins — it is newer and post-spike.

**Product in one sentence:** a keyboard that dictates and cleans up your writing entirely
on your device, sold once, that collects nothing — and can prove it.

---

## What the spike proved (the load-bearing facts)

1. **In-appex recording is impossible** — every capture path refused by `mediaserverd`.
2. **On-device `SFSpeechRecognizer` works from the appex** — 412–810 ms, ~0 MB charged
   (out-of-process daemon).
3. **The container relay works** — the app records at a gapless 48 kHz while backgrounded
   (`UIBackgroundModes: audio`) with the keyboard frontmost; the App Group carries state
   both ways. Measured, not theorized.
4. FoundationModels: `deviceNotEligible` on A13; A17 Pro+ verdict pending. The design
   treats the model tier as **upside, never load-bearing**.
5. Appex headroom ~67–72 MB. Everything in the keyboard must live in single-digit MB.

Unresolved and deliberately designed-around: **cold start** (a keyboard cannot launch its
container app). Until spike experiment 5 (Live Activity / `LiveActivityIntent` wake)
resolves it, the mic key degrades gracefully — see "Dictation states" below.

---

## Two targets, one engine

```
ios/Ara/
├── App/            Ara.app — SwiftUI container: onboarding, recorder+ASR service,
│                   dictionary/snippets editors, settings, paywall, privacy page
├── Keyboard/       AraKeyboard.appex — the custom keyboard (UIKit host + SwiftUI keys)
├── Shared/         RelayKit (App Group protocol) + engine glue + store gate + theme
└── [AraEngine]     ../../Sources/AraEngine compiled directly into both targets
                    (no SPM resolution — Foundation-only files, xcodegen source refs)
```

- **Bundle IDs:** `com.silpho.ara`, `com.silpho.ara.keyboard`. App Group:
  `group.com.silpho.ara`. Team `547LS36PQ8`, automatic signing.
- **Deployment target: iOS 17.0.** FoundationModels tier is availability-gated at runtime
  (26+ and eligible hardware only). The spike's 26.0 target was spike-only.
- **Swift 6 strict concurrency**, same discipline as macOS: `@Sendable` closures on every
  realtime/audio boundary, no non-Sendable captures crossing actors.

### The relay, productionized (RelayKit)

The spike's `RelayProbe` grows into a small shared protocol layer. App Group primitives
only — `UserDefaults(suiteName:)` for state, Darwin notifications
(`CFNotificationCenterGetDarwinNotifyCenter`) for sub-second cross-process signaling,
one JSON file in the group container for transcripts (defaults are for scalars, not
payloads).

```
Keyboard → app:  command = start | stop | cancel     (defaults key + Darwin ping)
App → keyboard:  heartbeat (frames, stamp)            every 0.5 s while armed
                 state = idle | armed | recording | transcribing | error(String)
                 transcript = { partial, final, seq } (JSON file + Darwin ping)
```

Rules learned the hard way, now invariants:
- `containerURL(forSecurityApplicationGroupIdentifier:)` **nil-check at startup on both
  sides** — `UserDefaults(suiteName:)` never errors when provisioning is broken; the
  container URL is the only honest detector. Surface the failure in UI, never silently.
- Every timestamp is wall-clock; staleness > 5 s means the other side is gone.
- The keyboard never blocks on the relay: reads are synchronous snapshots, updates arrive
  via Darwin observer → main-queue hop.

### Audio + ASR live in the app process

The keyboard cannot record (fact 1) and should not transcribe (its memory is precious and
ASR needs the audio anyway). The app owns the whole audio path: `AVAudioSession`
(`.playAndRecord`, `.measurement`) → `AVAudioEngine` tap → streaming
`SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`, partial results on) →
`LocalDictionary.apply` → transcript file → Darwin ping. The keyboard renders partials
live and inserts the final.

`requiresOnDeviceRecognition = true` is **non-negotiable** — it is the privacy label. If
on-device recognition is unavailable for the locale, dictation is unavailable; we never
fall back to Apple's server.

---

## The keyboard (free tier — must be a real keyboard, 4.4.1)

Hand-rolled QWERTY, no third-party keyboard framework — the appex stays tiny, dependency-
free, and auditable, which is the product's whole pitch. Not KeyboardKit: it solves
problems we don't have (20 locales, autocomplete) at a size and abstraction cost we can't
pay in this binary.

- **Three layers:** letters / numbers+punctuation / symbols. Shift with double-tap caps
  lock. Long-press popups for alternates — including Polish diacritics (ą ć ę ł ń ó ś ź ż)
  on their base keys; the layout stays QWERTY.
- **Keys are SwiftUI** inside the `UIInputViewController`'s hosting view. Haptics via
  `UIImpactFeedbackGenerator` (respecting the system keyboard-haptics setting), key-press
  highlight, no sound.
- **Snippets expand on boundary keys** (space / return / punctuation): last word run
  through `Snippets.expansion(for:)`; expansion replaces the trigger via
  `deleteBackward()` × trigger length, then `insertText`. Cheap, deterministic, offline.
- **No autocorrect-as-you-type in v1.** Custom keyboards get no system autocorrect, and a
  home-grown one is a product of its own. Ara's wedge is cleanup-on-demand, not
  keystroke prediction. `UITextChecker` powers the Clean action, not live squiggles.
- **Secure fields:** iOS forces the system keyboard for passwords — nothing to do, but
  onboarding says so ("works everywhere" is not claimed).
- **The suggestion bar** (top strip, 36 pt) is the only chrome: left = mic key state,
  center = live transcript / status text, right = **✨ Clean** action.

### Clean (the paid action)

Clean takes the current sentence (bounded by `documentContextBeforeInput`, whose
truncation varies by host and is measured in dev on the host matrix), runs
`RuleBasedFormatter` + `LocalDictionary` + `UITextChecker`, computes a **minimal suffix
diff**, and applies it as `deleteBackward()` × N + `insertText`. Invariants, verbatim from
the build plan because they are data-loss guards, not style:
- Never rewrite more than the visible sentence.
- Empty output for non-empty input **aborts before the first delete**.
- The diff is applied suffix-only; the untouched prefix is never deleted.

### Dictation states (the mic key)

| State | Condition | Mic key does |
|---|---|---|
| **Relay live** | purchased + Full Access + app heartbeat fresh | Own recording UI: key pulses amber, bar shows live partials, tap again to stop → final text inserted through the cleanup chain. Wispr Flow's UX, zero cloud. |
| **App cold** | purchased + Full Access, no heartbeat | Bar shows "Open Ara once to enable dictation" (deep-link chip if experiment 5 lands a wake channel, plain instruction until then). Mic key falls through to Tier B. |
| **No Full Access / not purchased** | — | Tier B: `hasDictationKey` stays unset so iOS draws the system dictation button; dictated text arrives as ordinary insertions. Free users get Apple's mic; purchase adds Ara's. |

The orange system mic indicator is on whenever the relay records. That is presented as a
feature — the Home screen explains "you can always see when Ara is listening; iOS makes it
impossible for us to hide it, and we wouldn't want to."

---

## The app

Five screens. VidNotes design standard throughout: pure-black `#000` background, one
accent — **Ara amber `RGB(255, 190, 118)`** carried over from macOS — no gradients, dark
onboarding, VidNotes-style paywall.

1. **Onboarding** (first launch, 3 dark full-screen steps):
   ① what Ara is (one sentence + the empty-privacy-label claim) →
   ② add the keyboard: deep link to Settings, with the exact toggle path spelled out,
   Full Access explained honestly (what it unlocks, that Ara has no network code in the
   keyboard) → ③ mic + speech permission requests, then "try it here" playground field.
2. **Home:** dictation card — big armed/recording state, one toggle ("Keep Ara ready to
   dictate"), heartbeat indicator, battery honesty line; plus a playground text field.
3. **Vocabulary:** Dictionary editor (canonical + variants, add/edit/swipe-delete) and
   Snippets editor (trigger + expansion), both reading/writing the **same JSON byte format
   as macOS** via `ConfigLocation` pointed at the App Group container — a Mac-edited file
   drops in unchanged, and that is advertised.
4. **Settings:** cleanup intensity (`CleanupIntensity` picker), haptics toggle,
   Restore Purchases, privacy page link, version.
5. **Paywall** (VidNotes style): one lifetime price, feature list (Ara mic + live
   dictation, Clean action, intensity control), "no subscription · no account · no
   server" as the closer. Presented from Home and from locked touchpoints, never inside
   the keyboard (4.4).

**Purchase: StoreKit 2 directly — no RevenueCat.** Divergence from the build plan,
deliberate: the privacy nutrition label stays literally empty only if no third-party SDK
phones anywhere. StoreKit 2 gives account-free restore (`Transaction.currentEntitlements`)
on Apple's rails. The entitlement is mirrored to the App Group as a boolean the keyboard
reads; the keyboard never sees StoreKit.

**Modes:** iOS keyboards cannot identify the host app (no supported API), so macOS-style
per-app modes are meaningless here. v1 ships the default mode + intensity control only.

---

## What v1 explicitly does not do

No account. No analytics, no crash SDK (Apple's opt-in crash reports only). No network
code in the keyboard target at all — enforced by review, provable by the empty label. No
emoji picker (the system globe long-press provides one keyboard away; v1.1 candidate). No
autocorrect. No Android (separate rewrite, deferred). No FoundationModels tier until the
A17 Pro verdict — the chain's fall-through design means enabling it later is additive.

## Risks carried forward

- **Jetsam has no crash report.** `os_proc_available_memory()` instrumentation ships in
  debug builds from day one; the appex budget line is checked in the host matrix.
- **`documentContextBeforeInput` truncation varies by host** — Clean's sentence scope is
  measured against Messages, Mail, Safari, Notes, Telegram, X before release.
- **Background-audio session lifetime** is unmeasured beyond 3 s deltas; the Home screen's
  armed state must survive route changes (`AVAudioSession.interruptionNotification`
  handling with auto-rearm).
- **App Review** on `UIBackgroundModes: audio` for a dictation app: the reviewer note
  explains the relay (recording only while the user dictates from the keyboard, indicator
  always visible, nothing stored, nothing transmitted).
