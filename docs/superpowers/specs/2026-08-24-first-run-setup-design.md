# First-run setup — design

## Why

Ara's first launch after an install does three slow things with nothing on
screen to explain them: it asks for two permissions it cannot work without, it
downloads a 1.6 GB model, and it spends about two and a half minutes letting
Core ML compile that model for this machine. Launched from Finder there is no
terminal to read, no Dock icon and no window — so the honest description of a
fresh install today is "nothing happens for three minutes".

The compile itself cannot be made shorter or split. It is one `MLModel.load`.
Measured on an M3 Pro: 139–195 s for `whisper-large-v3-turbo`'s audio encoder,
cached per (signing identity × model × macOS build), and thrown away entirely
if the process is quit partway through.

What can change is *when* the user meets it and *whether they are told*. A
first-run window turns an unexplained three-minute silence into a setup step
that says what it is doing and how long it lasts.

## Rejected: dictating on the GPU while the Neural Engine compiles

The audio encoder can run on the GPU instead, which skips the compile.
Measured in one session, same audio, through the same path:

| encoder        | warm load | per utterance |
|----------------|-----------|---------------|
| Neural Engine  | 1.7 s     | 0.49–0.56 s   |
| GPU            | 6.5 s     | 1.23–1.33 s   |

The Neural Engine is 2.5× faster per utterance, so the GPU cannot replace it.
Loading both — dictating on the GPU copy while the Neural Engine copy compiles
behind it — was considered and rejected on memory: it holds the model twice,
about 1.6 GB extra, on a machine that is already short of it.

## The window

Shown on first run only. One step at a time:

1. **Microphone.** A button raises the macOS prompt in-process.
2. **Accessibility.** A button opens the Settings pane. macOS only honours a
   new grant in a fresh process, so ara offers to restart itself once the
   toggle is on.
3. **Download the model.** Progress bar, whole percent.
4. **Prepare for this Mac.** The compile. Elapsed time, and the one sentence
   that matters: quitting now starts it over.
5. **Done.** The window closes, ara returns to `.accessory` and lives in the
   menu bar.

Steps 3 and 4 are not new work. They are the warm-up ara already runs at every
launch, reported to a window instead of to a pill nobody has met yet.

## When it is shown

Shown when any of these is true:

- the microphone permission is not granted,
- accessibility is not trusted,
- the chosen model is not on disk,
- `setupCompleted` is absent from the config.

The first three are read from live state, so a user who revokes a permission
meets the window again rather than a daemon that cannot work. The flag covers
the one thing that cannot be observed: whether the compile has ever finished.

## It is not only the first run

The compile is cached per (signing identity × model × macOS build), so
**every ara update pays it again** — and by then `setupCompleted` is true and
the window would be `nil` through the one wait it exists for. So the window
also opens mid-warm-up, when the transcriber reports
`preparingNeuralEngine` — the phase raised after twenty seconds of a load that
has stopped looking like a load. That one opens without taking the foreground:
it appears twenty seconds into a launch the user has already gone back to work
from, and it has nothing to ask them for.

## Branding

The window is the first thing a new user sees, so it carries the identity of
the iOS app rather than system defaults. `AraCore/UI/Brand.swift` is
`ios/Ara/Shared/Theme.swift` ported — same values, same names, `NSColor` in
place of `UIColor` — and the overlay pill and the menu-bar mark now read from
it too.

What came across: the graphite/warm-paper palette, the serif display face, the
monospaced micro-labels (`setup · 01 / 04`, `on device`), the primary button
(text colour as fill, background colour as label, radius 14), and the parrot
mark, whose Bezier paths are copied verbatim so the two platforms draw one
shape rather than two drawings of it.

The rules that came with it: amber marks the live microphone and nothing else
— not progress bars, not buttons — sentence case throughout, no exclamation
marks, and no congratulating the user for finishing a step ara asked them to
do.

Two things had to change for macOS, both found by rendering them: the
nine-bar mark is illegible below about 28 points, so the menu-bar icon is the
same profile as line art at 16; and a filled silhouette at that size is a blob,
which is why it is stroked.

## Structure

- `SetupFlow` (`AraCore`) — which step is current, and what each step says. No
  AppKit, fully unit-tested. Every rule lives here.
- `Brand` (`AraCore/UI`) — the palette, type and mark, ported from iOS.
- `SetupWindow` (`AraCore/UI`) — draws the flow and raises the prompts. No
  decisions.
- `Config.setupCompleted` — persisted through the existing `rewriteOneKey`
  path, the same way the model and language picks are.
- `Relaunch` — restarts ara after the accessibility grant.

## Testing

`SetupFlow` gets the step-order rules, the "shown when" rule, and the copy for
each step. The window is checked by the same off-screen `ImageRenderer` pass
the overlay uses, so its messages are pinned to fit.
