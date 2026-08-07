# Ara for iOS — building and testing

## Build

```bash
brew install xcodegen        # once
cd ios/Ara
xcodegen generate            # regenerates Ara.xcodeproj (git-ignored) after file adds
open Ara.xcodeproj
```

Run the `Ara` scheme on a physical device. Simulator builds compile but prove nothing
about dictation: the relay, background audio, and on-device recognition all behave
differently or not at all off-device.

**First device build:** automatic signing must register `group.com.silpho.ara` with the
team. If Xcode shows a provisioning error naming App Groups, open Signing & Capabilities
for BOTH targets and let it repair, then build again. The app's Home screen shows a red
warning if the group didn't take — believe it over a green build.

## Test checklist (device)

1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Ara → Allow Full Access.
2. App: complete onboarding, grant mic + speech, flip "Keep Ara ready to dictate" —
   orange mic indicator appears and stays.
3. Any app: switch to the Ara keyboard, tap the mic key, speak, tap again — text lands
   after on-device transcription. The app was in the background the whole time.
4. Kill the app from the app switcher, try the mic key: the bar must say to open Ara —
   this is the known cold-start boundary, not a bug (see the design doc).
5. Full Access OFF: keyboard still types, snippets still expand, system dictation button
   still works. Ara's own mic must degrade with an explanation, never crash.

## Host matrix (before any release)

`documentContextBeforeInput` truncation varies by host and bounds the Clean action. Type
a long paragraph and run Clean in each: Messages, Mail, Notes, Safari, Telegram, X.
Record how much context each returned and whether the suffix edit stayed inside the
visible sentence.

## Memory

The keyboard logs available memory (debug builds, os_log category `memory`). Watch it in
Console.app across repeated invocations — the extension process persists, so growth
between invocations is a leak even if a single invocation looks flat. Jetsam kills
keyboards without a crash report; the log line is the only early warning.

## App Review notes (paste into the review notes field)

Ara's container app declares `UIBackgroundModes: audio` because the keyboard extension
cannot record (iOS denies capture in `com.apple.keyboard-service`); the container app
performs the recording while the user dictates from the keyboard, entirely on-device via
`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Recording happens only
while the user has armed dictation in the app, the system microphone indicator is always
visible, audio is never stored, and nothing is transmitted — the keyboard target contains
no networking code. The keyboard remains fully functional without Full Access and without
network (guideline 4.4.1); purchase is in the app only (guideline 4.4).
