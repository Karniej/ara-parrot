# Ara for iOS — implementation plan

Executes `IOS-APP-DESIGN.md`. Branch `ios`. Each task ends buildable
(`xcodebuild -scheme Ara -destination 'generic/platform=iOS Simulator' build`); device
verification is the user's part at the checkpoints marked 📱.

## Global constraints (bind every task)

- Bundle IDs `com.silpho.ara` / `com.silpho.ara.keyboard`; App Group `group.com.silpho.ara`
  present in BOTH entitlements files with real content (the spike shipped empty plists —
  never again; `containerURL` nil-check guards it at runtime).
- Deployment iOS 17.0, Swift 6 strict concurrency. Audio-thread closures are `@Sendable`.
- No third-party dependencies anywhere. No network code in the keyboard target.
- `requiresOnDeviceRecognition = true` always; no server fallback.
- Theme: pure-black `#000`, single accent `RGB(255,190,118)`, no gradients (VidNotes
  standard). All copy sentence-case, no exclamation marks.
- Keyboard memory: no caches, no retained audio, assets tiny; debug builds log
  `os_proc_available_memory()` on appear.
- JSON formats byte-identical with macOS (`LocalDictionary`/`Snippets` codecs as-is).

## Tasks

1. **Scaffold + RelayKit + glue** — `ios/Ara/` xcodegen project (two targets, correct
   entitlements, AraEngine sources compiled in from `../../Sources/AraEngine`), `Shared/`:
   `Theme`, `RelayKit` (keys, state enum, Darwin notifier, transcript file store,
   container check), `EngineProvider` (dictionary/snippets/intensity loaded from App
   Group via `ConfigLocation`), `StoreGate` protocol + `AppGroupEntitlement` mirror.
   Builds green both targets.
2. **App dictation service** — `App/Dictation/`: `RecorderService` (session config,
   engine tap, interruption/route handling, auto-rearm), `SpeechService` (streaming
   on-device `SFSpeechRecognizer`, partials), `DictationCoordinator` (relay commands in,
   heartbeat + transcript out). Spike's `@Sendable` tap lesson applies verbatim.
3. **Keyboard QWERTY** — `Keyboard/`: `KeyboardViewController` (hosting + height),
   SwiftUI key grid, 3 layers, shift/caps double-tap, long-press popups with Polish
   diacritics, haptics setting-aware, snippet expansion on boundary keys, globe key
   (`needsInputModeSwitchKey` handling), backspace repeat.
4. **Suggestion bar + Clean** — bar (mic state / status text / ✨ Clean), Clean pipeline:
   sentence scope from `documentContextBeforeInput`, `RuleBasedFormatter` +
   `LocalDictionary` + `UITextChecker`, minimal suffix diff, the two data-loss guards
   (empty-output abort before any delete; prefix never touched).
5. **Keyboard relay client** — mic key drives RelayKit commands; live partial rendering
   in the bar; final insert through dictionary; the three mic states from the design
   table (relay live / app cold / Tier B fall-through with `hasDictationKey` unset).
6. **App screens** — Onboarding (3 steps + permissions + playground), Home (dictation
   card, armed toggle, heartbeat, playground), Vocabulary (dictionary + snippets
   editors), Settings (intensity, haptics, restore, privacy page).
7. **StoreKit 2 + paywall** — lifetime product, `Transaction.currentEntitlements`
   restore, entitlement → App Group mirror, VidNotes-style paywall, locked-state
   touchpoints in Home/Settings.
8. **Polish** — `PrivacyInfo.xcprivacy` (both targets), memory logging, reviewer notes
   file, README-IOS with build steps, host-matrix checklist doc.

📱 Device checkpoints: after 3 (typing feel), after 5 (end-to-end dictation via relay),
after 7 (purchase flow in sandbox).

## Sequencing

1 → {2, 3 in parallel} → 4 → 5 → {6, 7 in parallel} → 8. Parallel tasks touch disjoint
directories; the xcodegen project globs directories, so no project-file merges.
