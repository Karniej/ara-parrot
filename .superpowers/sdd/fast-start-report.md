# Fast start — where the minutes went

Branch `feature/fast-start`, based on `master` `0c7b734`. All measurements on
this machine: Apple M3 Pro, macOS 26.5.1 (build `25F80`), warm model cache at
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`, data volume 96%
full.

---

## 1. The measurement table

Every number below is a real load of a real model. The benchmark is
`Tests/AraCoreTests/WhisperLoadBenchmark.swift`, opt-in behind
`ARA_WHISPER_LOAD_BENCH=1`. The daemon was never launched.

### 1.1 `whisper-large-v3-turbo`, warm cache, phase by phase

Two loads in one process, twice over:

| phase                                  | run A r1 | run A r2 | run B r1 | run B r2 |
|----------------------------------------|---------:|---------:|---------:|---------:|
| `WhisperKit.download` (hub etag check) |  4638 ms |  4300 ms |  4622 ms |  4502 ms |
| `WhisperKit(config)` (no prewarm/load) |     2 ms |     0 ms |     3 ms |     0 ms |
| `prewarmModels()`                      |  1505 ms |  1442 ms |  1264 ms |  1322 ms |
| `loadModels()`                         |  1460 ms |  1851 ms |  1449 ms |  1367 ms |
| **total, master's config**             | **7606 ms** | **7594 ms** | **7338 ms** | **7191 ms** |
| first transcription                    |   629 ms |   572 ms |   562 ms |   954 ms |
| second transcription                   |   677 ms |   555 ms |   689 ms |   648 ms |

`prewarm: false`, same conditions: load **952–1487 ms**, first transcription
**544–694 ms**. Prewarm bought nothing: it is a *second* full load
(`WhisperKit.init` runs `loadModels(prewarmMode: true)` then `loadModels()`, and
prewarm mode discards its result — `WhisperMLModel.loadModel` keeps
`prewarmMode ? nil : loadedModel`).

**`warmUp()` end to end, as this branch now ships it: 949–1036 ms.**

### 1.2 Is it every launch, or only the first?

Only the first — but "first" is not per machine. Identical binary, two separate
processes, nothing rebuilt in between:

| run                                            | `warmUp()` |
|------------------------------------------------|-----------:|
| first process under a never-seen client identity | **150 355 ms** (encoder specialisation 140.97 s) |
| second load, same process                       | 7 183 ms (specialisation 1.06 s) |
| second **process**, same identity               | 7 338 ms (specialisation 1.07 s) |

So the cost is paid once per client identity and then persists across processes.
`whisper-base.en` for comparison: **11 255 ms** first, **491 ms** after.

### 1.3 What `prewarm: false` costs instead

Nothing. It does not avoid the specialisation — that happens inside
`MLModel.load` whichever pass reaches it first — and the first utterance is
0.54–0.69 s either way. It only stops the model being loaded twice.

### 1.4 The compute-units alternative

`audioEncoderCompute: .cpuAndGPU` is the one config change that skips the ANE
compile:

| | cold (new identity) | warm load | utterance 1 | utterances 2–3 |
|---|---:|---:|---:|---:|
| `.cpuAndNeuralEngine` (today) | 141–187 s | 0.95–1.5 s | 0.56 s | 0.52–0.69 s |
| `.cpuAndGPU`                  | **29.6 s** | 4.4 s | 4.0 s | 1.1–1.3 s |

A bad trade: it converts a **one-time** 2.5 minutes into a permanent 3.4 s of
extra startup and roughly double the per-utterance latency, forever. Rejected.

---

## 2. The cache finding

**`~/Library/Caches/com.apple.e5rt.e5bundlecache` reporting 0 bytes across 16
directories is a red herring.** Those directories are keyed `24G90` — macOS 15.6.
This machine runs `25F80`. On macOS 26 the ANE bundle cache moved to a
**per-client** location:

```
~/Library/Caches/<client>/com.apple.e5rt.e5bundlecache/<macOS build>/<hash>/<hash>.bundle
```

Live directories found: `ara` (1.1 GB), `com.silpho.ara` (1.2 GB),
`swiftpm-testing-helper` (191 MB), `com.apple.duetexpertd`. So specialisation
results **do** persist — just not where we looked.

### 2.1 What the key actually is

Tested directly, by re-signing the same binary and re-running:

| probe | signing identifier | cdhash | `warmUp()` |
|---|---|---|---:|
| baseline | `swiftpm-testing-helper-5555…ba58` | X | 0.95 s (hit) |
| re-signed ad-hoc | `anefresh1-5555…4eb4` | Y | **186 606 ms** (miss) |
| same identifier, different cdhash (extra `LC_RPATH`) | `anefresh1-5555…4eb4` | Z | **1 675 ms** (hit) |
| same identifier, same cdhash | `anefresh1-5555…4eb4` | Y | 5 727 ms (hit) |

**The key is the code-signing identifier, not the cdhash.** Same identifier with
a different binary hits the cache; a different identifier misses it entirely.

### 2.2 Therefore: rebuild-invalidation is *not* the cause — hypothesis rejected

`.build/release/ara` is ad-hoc signed with `Identifier=ara`, plain, name-derived
and stable across every relink. The user's ~15 rebuilds today did **not**
invalidate anything. `/Applications/Ara.app` is `com.silpho.ara`, also stable.
Part 2 does not become unnecessary for that reason, and no dev-build warning is
warranted.

### 2.3 What *is* the cause

The specialisation is **all or nothing**. Measured: a fresh-identity compile was
killed 75 s into its 145 s. It left 905 MB of intermediate on disk and preserved
**zero** progress — the next run paid the full 145 185 ms again.

And the evidence on this machine says that is exactly what has been happening:

```
~/Library/Caches/ara/…/25F80/EF0D04DE…/3315A492….tmp.67058_36825122048.bundle          1.1 GB
~/Library/Caches/com.silpho.ara/…/25F80/30781E04…/ACF20F3E….tmp.63051_44507516480.bundle 1.2 GB
```

`.tmp.<pid>_<n>.bundle` is an abandoned in-flight compile. **Neither `ara` nor
`com.silpho.ara` holds a single completed audio-encoder bundle.** That compile
has never once been allowed to finish. Every launch restarted the 2.5 minutes;
every impatient quit threw it away. That is "3 minutes, and 10+ on the last run".

Also: 2.3 GB of dead intermediate on a volume that is 97% full. Safe to delete —
`find ~/Library/Caches/{ara,com.silpho.ara} -name '*.tmp.*.bundle' -maxdepth 4`.

### 2.4 Why MLX loads in 3 s next door

MLX runs on the GPU through Metal. There is no Core ML model, no ANE, and
therefore no specialisation to compile or cache. It is not a comparable
measurement.

### 2.5 On the unified log

`process == "ANECompilerService"` returns nothing because the daemon logs under
`runningboardd` and `com.apple.coreml`. Querying by message content finds it
(33 XPC resolutions in 24 h, mostly system daemons). It was not needed in the
end — the on-disk cache is a better witness than the log.

---

## 3. Was Part 2 warranted? No.

**What shipped instead, with before/after:**

| | master | this branch |
|---|---:|---:|
| warm start, `whisper-large-v3-turbo` | 7 191–7 606 ms | **949–1 036 ms** |
| — of which hub etag check over the network | 4 300–4 638 ms | 0 (skipped when the model is on disk) |
| — of which a second, discarded model load | 1 264–1 505 ms | 0 (`prewarm: false`) |
| first-ever specialisation | 141–187 s, silently labelled "loading…" | 141–187 s, labelled and explained at 20 s |

A **7.5×** cut to the wait that happens every single launch, plus the one-time
wait made survivable.

**Why tiering is not worth the complexity:**

1. The recurring wait is now 1.0 s. Tiering cannot improve on that and can only
   put a worse model in front of it.
2. The remaining long wait happens **once per (identity × model × macOS build)**,
   and it is Core ML's compile — tiering does not shorten it, it only hides it.
3. The constraint "never download the fast model just to tier" removes most of
   the population it would help: a user who chose `large-v3-turbo` generally does
   not have `base.en` on disk. When they do not, `fastStart` is dead config.
4. When they *do* have it, `base.en` has its own first specialisation to pay —
   11.3 s measured — so even the best case is "seconds instead of minutes", once,
   ever.
5. Against that: a second pipeline, a swap protocol that must never fire
   mid-utterance, and a UI contract for announcing degraded quality. Silent
   quality variation is the failure mode the spec itself names, and every one of
   those mechanisms is live on *every* launch to buy something that happens on
   one.

The diagnosis says the user's pain was never the steady state — it was a
2.5-minute compile that looked like a hang, got killed, and restarted forever.
Naming the wait addresses that directly. Tiering would not have: it would have
handed them `base.en` while the same doomed compile ran behind it.

**When to revisit:** if the product decides a first launch must be usable within
seconds regardless, tiering is the only remaining lever — the compile itself
cannot be shortened, and the `.cpuAndGPU` escape costs more than it saves
(§1.4).

---

## 4. What was built

| commit | |
|---|---|
| `71c6065` | `bench:` the opt-in phase-split benchmark |
| `6a153bb` | `perf:` load a cached model from disk instead of re-checking it with the hub |
| `c4b7895` | `perf:` stop loading every Core ML model twice at startup |
| `45ce87c` | `feat:` say when a load is really the Neural Engine compile, and that it is once |
| `da2f03b` | `fix:` show the repair's download instead of hiding it behind "loading…" |

**`WhisperWarmupPlan`** (new, unit-tested): decides `.local` vs `.hub`, and
retries a failed local load against the hub exactly once — so the truncated-
download repair the etag check used to perform pre-emptively still happens, on
the launch it is needed rather than every launch. Also owns
`specialisationThreshold` (20 s) and `specialisationNotice(model:)`.

**`TranscriberWarmup.preparingNeuralEngine`** (new phase) plus
`advances(from:to:)`, which now owns the whole report-ordering rule: warm is
terminal, a download percentage never walks backwards, and the Neural Engine
notice is not taken back by a `.loading` still in flight behind it. The daemon's
`WarmupState.setTranscriber` used to spell two of those out inline, untested;
they are unit-tested now.

**The watchdog**: a load still running after 20 s reports
`.preparingNeuralEngine` and writes to stderr. 20 s because `base.en`'s own first
specialisation is 11.3 s and finishes before anyone reaches for the quit key;
the large model's does not.

Verified end to end against a real cold specialisation:

```
loading whisper-large-v3-turbo...
still preparing whisper-large-v3-turbo for the Neural Engine. macOS compiles
each model for this machine one time — a few minutes for the large models —
and quitting before it finishes starts it over.
✓ whisper-large-v3-turbo ready
    150839 ms  warmUp()
```

…and silent on the warm path, which is unchanged.

**Verification**: `swift test` — 619 tests in 56 suites, all passing (592 at
base, +11 from `WhisperWarmupPlan`, +12 for the phase rules and the notice, +4
inert benchmark cases). `swift build -c release` — clean.

### 4.1 Fixed in review

**The repair path was invisible.** `advances(from:to:)` rejected every
`.downloading` that followed `.loading`, on the reasoning that such a report can
only be a stale out-of-order hop. It can also be
`WhisperWarmupPlan.attempt`'s repair — a model that passed `isPresent` but
failed to load, falling back to the hub — and in that case the pill has been on
`.loading` since before the first attempt. The result was an entire 1.6 GB
re-download shown as "loading whisper-large-v3-turbo…", with no progress and no
watchdog (the watchdog only arms once the download is over). That is the same
multi-minute unexplained wait this branch exists to remove, reintroduced on the
path this branch created — and a regression against `master`, which filtered
only backwards percentages.

The two cases are distinguishable, so the rule now distinguishes them rather
than picking a side: `.downloading(percent: nil)` is emitted once, synchronously,
at the top of the hub branch, and the coalescer only ever emits whole percents —
so the indeterminate frame is the repair's signature and it alone may reopen the
download. Its percentages then flow through the existing `.downloading` rule. A
stale hop, which always carries a number, still cannot walk the pill backwards.
Same fix for `.preparingNeuralEngine → .downloading`, which otherwise claimed the
Neural Engine was being prepared for the length of a re-download.

Four tests pin it, including the full repair sequence end to end.

**"one time" was a promise the next system update breaks.** The cache path is
`…/com.apple.e5rt.e5bundlecache/25F80/…` — the key includes the OS build, which
`TranscriberWarmup`'s own doc said and the user-visible strings did not. Every
macOS update costs another 141–187 s. All user-visible strings and docs now say
**"once per macOS version"**, and a test asserts the phrase "one time" does not
appear. The two other components of the key do not need saying: users do not
rebuild `ara`, and switching models is a choice they made.

The exact strings, since they are being quoted:

> **pill / menu line** — `preparing whisper-large-v3-turbo for the Neural Engine — once per macOS version, a few minutes…`
>
> **stderr** — `still preparing whisper-large-v3-turbo for the Neural Engine. macOS compiles each model for this machine once per macOS version — a few minutes for the large models — and quitting before it finishes starts it over.`

**`attempt` answered cancellation with a hub round trip.** A `CancellationError`
means the daemon is shutting down or the warm-up was superseded; spending a
user's network on a repair nobody is waiting for is wrong, and since the hub call
is itself cancellable it mostly reaches the same error again, slower. Rethrown
now, with a test.

**The repair's cause was discarded.** `attempt` throws the *hub's* error when
both attempts fail, so `onRepair` is the only place the first fault can still be
reported — and it is the answer to "why is this suddenly downloading 1.6 GB?".
`onRepair` now takes the error and the transcriber names its type in the line.

**The benchmark re-planted the misconception.** `cacheSize()` still measured
`~/Library/Caches/com.apple.e5rt.e5bundlecache` — the macOS 15 path this report
proves reads 0 on macOS 26 — so every future run would print `0 → 0` and teach
the next reader exactly the wrong thing. It now resolves the calling process's
own caches directory, which is the per-client path that actually grows.

---

## 5. Concerns

1. **`prewarm: false` on a cold ANE cache moves the wait, it does not remove it.**
   The 2.5 minutes now lands inside `loadModels()` instead of `prewarmModels()`.
   No user-visible difference, but a future reader comparing profiles will see
   the time move.
2. **The 20 s threshold is a heuristic, not a detection, and `whisper-small.en`
   was never measured.** It is not on this machine, and fetching 488 MB onto a
   97%-full volume to time it was not worth it. Interpolating by encoder
   parameter count between the two points that *were* measured — `base.en`
   (~20 M, 11.3 s) and `large-v3-turbo` (~635 M, 141 s) — puts `small.en`
   (~88 M) at roughly **25 s**, i.e. just over the line. It would therefore show
   the notice for a wait of about half a minute. That is survivable: the
   sentence hedges with "a few minutes *for the large models*", so it is
   over-dramatic rather than false, and raising the threshold to clear it would
   delay the notice in the case that actually matters. Worth a real measurement
   if anyone downloads that model. A machine slower than an M3 Pro moves every
   number in the same direction.
3. **`isPresent` still cannot see a truncated `weight.bin`.** Skipping the hub
   means a partial download is caught by the load failing rather than by an etag
   comparison. The fallback covers it, but the first symptom is now a Core ML
   error in the logs rather than a silent re-fetch.
4. **The repair path is unit-tested, not exercised.** The phase rule and the
   full report sequence are pinned by tests, but no run in this investigation
   actually corrupted a `.mlmodelc` to watch a real fallback download render.
   Doing so means deliberately damaging the user's 1.5 GB model cache and
   re-fetching it on a 97%-full volume, which is why it was not done. The two
   pieces either side of the rule — `attempt`'s retry and `load`'s hub branch —
   are each covered; it is their composition on screen that is inferred.
5. **2.3 GB of orphaned `.tmp.` bundles are still on this machine** (§2.3) on a
   97%-full volume. Not deleted — that is the user's cache, and the command is in
   this report.
6. **The next `ara` launch will still cost ~2.5 minutes**, because that compile
   has genuinely never completed. It should be the last one, provided it is not
   interrupted — which is precisely what the new notice is for.
