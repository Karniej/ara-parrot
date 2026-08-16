# Warm-up ladder: dictate on a small model while the chosen one loads

## The problem

`ara run` cannot dictate until the chosen transcription model is loaded. On
`whisper-large-v3-turbo` — the model a user who wants accuracy picks, and the
one this project's author runs — that is measured on an M3 Pro at:

| state                                   | wait      |
|-----------------------------------------|-----------|
| warm cache, already specialised          | ~1.0 s    |
| warm cache, first Neural Engine compile  | 141–187 s |
| cold cache                               | 1.6 GB download, then the above |

The daemon already explains the wait well: `WarmupStatus` names the phase, the
percentage rides the pill headline, and `WhisperWarmupPlan.specialisationNotice`
tells the user that quitting throws the compile away. Explaining a three-minute
wait is not the same as not having one.

`whisper-base` loads in a fraction of that and transcribes well enough to be
useful. Nothing in the design requires the *first* model loaded to be the
*chosen* one.

## The shape of the fix

Load a small model in parallel with the chosen one. Open the dictation gate on
whichever lands first. When the chosen model lands, adopt it. The user dictates
in seconds and never presses a key that does nothing.

The swap machinery already exists and is not redesigned here.
`beginModelSwitch` (`Sources/ara/Ara.swift`) builds a pipeline off the actor
while the running one keeps serving utterances, then calls
`WhisperKitTranscriber.adopt`. The ladder is that same move with the roles
reversed: the small model is the one that gets replaced.

## Decisions

### The trigger is a deadline, not a probe

The ladder should not run when the chosen model is already warm — a second
model load that nobody waits for is pure waste.

"Already warm" cannot be tested directly. A missing download is easy
(`WhisperModelStore.isPresent`), but the multi-minute case is a missing Core ML
specialisation, cached under
`~/Library/Caches/<client>/com.apple.e5rt.e5bundlecache/<macOS build>/…` and
keyed on the signing identity, the OS build and the model. Probing that path
means reimplementing a private cache layout, and a wrong answer gives the worst
outcome available: a three-minute wait with the ladder switched off.

So the ladder measures instead of guessing. The chosen model's load starts
alone. If it has not returned within `WarmupLadder.bootstrapDelay`, the
bootstrap load starts alongside it. A warm launch returns first and never
starts a second load; a cold one does not, and is dictating shortly after.

The delay is **5 seconds**, measured rather than guessed. Through the daemon's
own path — `WhisperKit(config)` with `prewarm: false`, which is what
`WhisperKitTranscriber.load` uses and is not the `loadModels()` row in the
table above — on an M3 Pro:

| load                                    | seconds |
|-----------------------------------------|---------|
| large-v3-turbo, warm and specialised    | 2.45    |
| whisper-base, warm and specialised      | 0.47    |
| whisper-base, first specialisation      | 2.4     |
| large-v3-turbo, first specialisation    | 149     |

A 3 s delay would have fired on a merely busy machine. Five clears the slowest
warm load with margin and is 3% of the wait it exists to shorten. The two
errors are not symmetric: too long costs a cold start a few seconds it was
going to spend anyway, too short starts a load nobody needs.

### The bootstrap model is multilingual

`ModelRegistry.shared` has two small models and both are English-only
(`whisper-base.en`, `whisper-small.en`). Either would transcribe Polish as
English nonsense for the first minute of every cold launch — breaking exactly
the users `LanguagePolicy` and the Language submenu were built for.

The bootstrap is therefore `openai_whisper-base`, the multilingual variant, from
the same `argmaxinc/whisperkit-coreml` repo, ~145 MB. It matches
`whisper-large-v3-turbo`'s language capability, so no language setting can make
the ladder produce a wrong-language transcript.

It lives in `ModelRegistry.bootstrap`, **not** in `ModelRegistry.shared`. The
Model submenu lists models a user might want; a deliberately worse model that
the daemon uses as a stopgap is not one of them, and listing it would invite a
user to pick it permanently by mistake.

### The ladder does not run when it cannot help

`WarmupLadder.bootstrap(for:)` returns `nil` when the chosen model is the
bootstrap itself, or is no larger than it. A user who chose `whisper-base.en`
gains nothing from loading a second model of the same size, and paying a
download for one would be a net loss.

### A transcriber failure is fatal only when nothing is serving

Today a failed transcriber warm-up is `Darwin.exit(1)`, and that is right: a
daemon that cannot transcribe is not a daemon. With a ladder it stops being
right. If the chosen model fails to load but the bootstrap is serving, the user
has working dictation, and killing the process would take it away to punish a
failure that cost them nothing.

So the rule becomes: exit only when nothing is serving. A chosen-model failure
with the bootstrap live is a stderr line and a menu state
(`ModelSwitch.failed`), which is what a failed *live* switch already does.

### The gate opens through `WarmupState.finish`, not a new status field

An earlier draft gave `WarmupStatus` a `serving` field so `blocksDictation`
could account for the stand-in. It is not needed. `WarmupState.finish()` already
means "the wait is over and a press records", it is already one-way, and the
stand-in's adoption is exactly that event happening earlier than usual. The only
consequence is that `finish()` becomes reachable twice — once from the ladder,
once from the ordinary completion — so `declareReady` is made idempotent and
reports whichever model is actually running.

### What the user sees

The menu bar carries it. `ModelLabel.text` already renders
`model: whisper-base → loading whisper-large-v3-turbo…`, which is exactly true
during the ladder, and `ModelSwitch.loading` already means what it needs to
mean.

The overlay carries it once. `RecordingOverlay.State.recording` gains a
`note: String?`, rendered as the same quiet second line `.warmingUp` uses. The
first press while the bootstrap is serving carries the note; every press after
it carries `nil`. One press is enough to answer "why is this transcript worse
than usual?" and repeating it every press would be the friction the ladder
exists to remove.

The pill's headline stays the waveform. This is a recording, not a status
message — the gate is open and the audio is being captured.

## Components

| unit | responsibility |
|------|----------------|
| `ModelRegistry.bootstrap` | the one small multilingual model, outside `shared` |
| `WarmupLadder` | pure policy: the delay, whether a bootstrap helps, which result may be adopted, when a failure is fatal |
| `WarmupStatus.serving` | whether the bootstrap is serving, so `blocksDictation` and `message` agree with the gate |
| `RecordingOverlay.State.recording(note:)` | the one-time pill line |
| `Ara.run`'s warm-up task | the concurrency: two loads, whichever-first adoption, generation discipline |

`WarmupLadder` holds every rule a test can reach, for the reason
`WhisperWarmupPlan` and the `*MenuModel` types exist: the concurrency in
`Ara.run` is not unit-testable, so nothing that decides anything may live there.

## Adoption rules (the part that races)

Both loads run concurrently and either may return first. `RunningModel.generation`
already exists for exactly this and is reused rather than duplicated.

1. The chosen model, whenever it lands, is always adopted — unless a *newer*
   user pick has superseded it, which the existing generation check decides.
2. The bootstrap is adopted only if the chosen model has not landed yet. A
   bootstrap that returns after the chosen model is discarded silently; adopting
   it would downgrade a user who is already on the good model.
3. The gate (`WarmupState.finish`) opens on the first adoption of either.
4. A bootstrap failure is never reported to the user. It is an optimisation that
   did not happen, and the chosen model's own wait and its own messages are
   unchanged by it.

## Testing

Unit, in `WarmupLadderTests`:
- `bootstrap(for:)` returns `nil` for the bootstrap itself and for models no
  larger than it, and the bootstrap for `whisper-large-v3-turbo`.
- The adoption rule in both orders, including the bootstrap-after-target race.
- `isFatal(targetFailed:bootstrapServing:)` in all four combinations.

- `servingNote` names the model still loading and does not tell the user to
  wait.

Manual, in `docs/MANUAL-VERIFICATION.md` section 0ter. The command-line half is
observable without a human and was run on an M3 Pro on 2026-08-16, against a
genuinely undownloaded `whisper-small.en`:

```
downloading whisper-small.en (488 MB, one time)...
whisper-small.en is still loading; bringing up whisper-base to dictate on in the meantime...
loading whisper-base...
✓ whisper-base ready
listening on right ⌥ hold · model: whisper-base · ^C to quit     ← 17 s after launch
loading whisper-small.en...
still preparing whisper-small.en for the Neural Engine...
✓ whisper-small.en ready
```

The warm case was checked in the same session: with `whisper-large-v3-turbo`
already on disk and specialised, the gate opened in 6 s and the ladder never
started.

**A trap for whoever measures this next.** A `swift build` binary has no
`mlx.metallib`, and the MLX formatter's failure path burns ~180 s of CPU that
starves both Whisper loads. Every model load then looks like a Neural Engine
compile, including a 145 MB one that takes 2.4 s in isolation. That reading
produced one wrong diagnosis — apparent compile contention between the two
models — and a fix for it that was written and then reverted. Set
`"engine": "rules"` or run `scripts/build-metallib.sh` before believing any
number from a SwiftPM build.

## Not in scope

- Downloading the bootstrap ahead of time. On a genuinely first run the
  bootstrap pays its own ~145 MB download and ~11 s specialisation. That still
  beats 1.6 GB plus three minutes, and pre-fetching it at install time is a
  separate change to `ara install`.
- Keeping the bootstrap resident after the swap. `adopt` releases the old
  pipeline, and holding a second Whisper model in memory forever to save a
  future launch is the wrong trade.
