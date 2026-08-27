import Foundation
import WhisperKit

public actor WhisperKitTranscriber: SpeechTranscriber {
    /// Which model the *running* transcriber is actually using — not what
    /// `config.json` says. The Model submenu can change the saved value while
    /// this one is still serving utterances from the old pipeline, and the menu
    /// header reports this one.
    ///
    /// Lock-guarded rather than actor-isolated because `Transcriber` requires a
    /// synchronous read, and because the caller that most wants it is the menu
    /// on the main actor — which must not `await` a transcriber that is busy
    /// inside a several-minute model load to redraw a label.
    private let modelIDLock = NSLock()
    nonisolated(unsafe) private var _modelID: String
    public nonisolated var modelID: String {
        modelIDLock.withLock { _modelID }
    }
    private var model: TranscriptionModel
    private var pipeline: WhisperKit?

    /// Which language(s) to transcribe in. Mutable because it genuinely
    /// applies per utterance — `DecodingOptions` are built inside
    /// `transcribe`, so the Language submenu can change the answer for the
    /// *next* utterance without a restart, unlike the model, the hotkey or
    /// the engine.
    private var language: LanguageSetting

    /// The language the previous utterance ended up in, when it was one of the
    /// monitored ones. The whole point of `LanguagePolicy.lastLanguageBias`:
    /// a marginal detection stays where the session already was rather than
    /// flapping on a two-word utterance.
    ///
    /// Deliberately not persisted. It is session state, and writing the config
    /// file after every dictation to remember it would be a lot of I/O and a
    /// lot of ways to corrupt a file, for a prior that costs one utterance to
    /// re-establish.
    private var lastUsedLanguage: String?

    public init(model: TranscriptionModel, language: LanguageSetting = .automatic) {
        self._modelID = model.id
        self.model = model
        self.language = language
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    ///
    /// ## Why the download is performed here rather than by `WhisperKit`
    ///
    /// `WhisperKit.init` already does exactly this: with no `modelFolder` and
    /// `download: true` (the default), `setupModels` calls
    /// `WhisperKit.download(variant:…)` itself — and passes no
    /// `progressCallback`, so a 1.5 GB first run reports nothing for over a
    /// minute. Calling it ourselves and handing the resulting folder straight
    /// back through `modelFolder` is the *same* call with the callback filled
    /// in: same repo, same variant string, same hub cache. `download: false` on
    /// the config then only says "the folder is already decided".
    ///
    /// ## …but only when there is something to download
    ///
    /// It used to run on every launch, warm cache or not, because the etag
    /// check it performs is also the repair for a truncated download. That cost
    /// 3.7–6.1s of network on the path that gates dictation — see
    /// `WhisperWarmupPlan`, which now decides between the folder on disk and
    /// the hub, and keeps the repair by falling back to the hub when a local
    /// load actually fails.
    ///
    /// The percentage is real but **file-count weighted**, not byte weighted:
    /// `HubApi.snapshot` gives every file in the repo one unit of a `Progress`
    /// regardless of size, so a variant whose bytes live in three weight files
    /// among twenty advances in lumps. It is the only measure the downloader
    /// exposes — `getFilenames` returns names, and the per-file handler
    /// reports a fraction, never a byte count — and it is the same one
    /// `ara models download-formatter` has always printed.
    ///
    /// - Parameter onPhase: what the warm-up is doing, for the overlay. Called
    ///   from arbitrary threads (the download's callback runs on a
    ///   `URLSession` thread) and already coalesced to one report per whole
    ///   percent — the caller's job is only to hop.
    public func warmUp(
        onPhase: @escaping @Sendable (TranscriberWarmup) -> Void = { _ in }
    ) async throws {
        if pipeline != nil { return }
        pipeline = try await Self.buildPipeline(model: model, onPhase: onPhase)
    }

    /// Builds a loaded pipeline for `model`, downloading and repairing as
    /// needed. Everything `warmUp` used to do inline, hoisted to `static` so a
    /// live switch can run it off the actor — see `load`.
    public static func buildPipeline(
        model: TranscriptionModel,
        onPhase: @escaping @Sendable (TranscriberWarmup) -> Void = { _ in }
    ) async throws -> WhisperKit {
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        // Which of the two waits this is going to be, before either starts:
        // the download's own first report cannot arrive until the file listing
        // has come back over the network, and calling a warm start's
        // etag check "downloading" for those seconds would be a lie the pill
        // then has to take back.
        let source = WhisperWarmupPlan.source(
            present: WhisperModelStore.isPresent(model),
            directory: WhisperModelStore.directory(for: model))
        // The repair, when it is needed: a folder that passed `isPresent` but
        // did not load is the truncated download the hub's etag check used to
        // fix pre-emptively on every launch — see `WhisperWarmupPlan`. `attempt`
        // allows exactly one fallback, so this cannot loop.
        let id = model.id
        let built = try await WhisperWarmupPlan.attempt(from: source, onRepair: { _, error in
            // The fault is named, not just the reaction to it. This is the only
            // place the first error can still be reported — the caller gets the
            // hub's — and it is the answer to the question a user watching an
            // unexpected 1.6 GB download actually has.
            FileHandle.standardError.write(Data(
                ("\(id) did not load from disk (\(type(of: error))); "
                    + "re-checking the download...\n").utf8))
        }) { source in
            try await load(model: model, from: source,
                           variant: whisperKitID, onPhase: onPhase)
        }
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
        return built
    }

    /// Adopts an already-loaded pipeline as the running one.
    ///
    /// Split from `buildPipeline` because that is the part that takes minutes
    /// and this is the part that must not: actor isolation serialises this
    /// against `transcribe`, so the swap lands cleanly between two utterances
    /// and never inside one. The old pipeline is released here, which is also
    /// what keeps two Whisper models from staying resident after a switch.
    ///
    /// `lastUsedLanguage` is dropped: it is a prior about how *this* model
    /// hears the user, and carrying an English-only model's history into a
    /// multilingual one is exactly the stale bias `setLanguage` clears.
    public func adopt(_ pipeline: WhisperKit, model: TranscriptionModel) {
        self.pipeline = pipeline
        self.model = model
        modelIDLock.withLock { _modelID = model.id }
        self.lastUsedLanguage = nil
    }

    /// Resolves a `ModelSource` to a folder and builds the pipeline from it.
    ///
    /// ## `prewarm` is deliberately off
    ///
    /// It used to be `true`, which is not a cheap flag: `WhisperKit.init` runs
    /// `loadModels(prewarmMode: true)` and then `loadModels()`, and prewarm
    /// mode throws its result away (`model = prewarmMode ? nil : loadedModel`
    /// in `WhisperMLModel.loadModel`). Every compiled model is therefore
    /// `MLModel.load`ed **twice**, back to back, for a specialisation the
    /// second load would perform anyway. Measured warm on an M3 Pro:
    ///
    /// | variant                | prewarm pass | load pass | first utterance |
    /// |------------------------|--------------|-----------|-----------------|
    /// | large-v3-turbo, prewarm| 1.2–1.5s     | 1.3–1.9s  | 0.56–0.95s      |
    /// | large-v3-turbo, without| —            | 0.95–1.5s | 0.54–0.69s      |
    /// | base.en, prewarm       | 0.19s        | 0.48s     | 0.10s           |
    /// | base.en, without       | —            | 0.47s     | 0.10s           |
    ///
    /// So it charged 1.2–1.5s of startup and bought nothing measurable back
    /// on the first utterance. Startup is the wait the user is standing in
    /// front of. `nil`/`false` is also WhisperKit's own default.
    ///
    /// It does **not** avoid the one-time Core ML specialisation for the
    /// Neural Engine — that happens inside `MLModel.load` whichever pass
    /// reaches it first, and costs whole minutes on the large model. See
    /// `specialisationNotice` and the report in
    /// `.superpowers/sdd/fast-start-report.md`.
    /// `static` for the same reason `downloadModel` is, and for one more: a
    /// live model switch builds its pipeline through `buildPipeline` *without*
    /// holding actor isolation, so utterances keep being served by the old
    /// pipeline throughout a load that can take minutes. An isolated loader
    /// would queue every `transcribe` behind the Neural Engine compile.
    private static func load(
        model: TranscriptionModel,
        from source: ModelSource, variant: String,
        onPhase: @escaping @Sendable (TranscriberWarmup) -> Void
    ) async throws -> WhisperKit {
        let folder: URL
        switch source {
        case .local(let directory):
            onPhase(.loading)
            folder = directory
        case .hub:
            onPhase(.downloading(percent: nil))
            FileHandle.standardError.write(Data(
                ("downloading \(model.id) "
                    + "(\(ModelSize.label(megabytes: model.sizeMB)), one time)...\n").utf8))
            folder = try await Self.downloadModel(variant: variant, onPhase: onPhase)
            onPhase(.loading)
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: variant, modelFolder: folder.path,
                                      verbose: false, prewarm: false, load: true,
                                      download: false)
        let notice = Self.specialisationWatchdog(model: model.id, onPhase: onPhase)
        defer { notice.cancel() }
        return try await WhisperKit(config)
    }

    /// Says what a load that has stopped looking like a load is doing.
    ///
    /// Unstructured on purpose: `WhisperKit.init` is one long `await` with no
    /// progress of its own to hook, so the only way to report anything from
    /// inside it is a task racing alongside. Cancelled by the `defer` at the
    /// call site, so a load that returns in a second says nothing at all.
    ///
    /// Nothing here touches actor state, which is why it is `static`: it is
    /// called from an actor-isolated method but must keep running while that
    /// method is suspended inside Core ML.
    private static func specialisationWatchdog(
        model: String, onPhase: @escaping @Sendable (TranscriberWarmup) -> Void
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: WhisperWarmupPlan.specialisationThreshold)
            guard !Task.isCancelled else { return }
            FileHandle.standardError.write(Data(
                WhisperWarmupPlan.specialisationNotice(model: model).utf8))
            onPhase(.preparingNeuralEngine)
        }
    }

    /// The download, with its progress stream reduced to whole percents.
    ///
    /// `static` deliberately: the progress callback is invoked on a foreign
    /// thread, and building it inside an actor-isolated method would make it
    /// an actor-isolated closure being called from off the actor. Nothing here
    /// touches actor state, so nothing needs to be.
    private static func downloadModel(
        variant: String, onPhase: @escaping @Sendable (TranscriberWarmup) -> Void
    ) async throws -> URL {
        let coalescer = ProgressCoalescer()
        return try await WhisperKit.download(variant: variant) { progress in
            guard let percent = coalescer.step(progress.fractionCompleted),
                  // 100% is not a state worth showing: it means the download
                  // is over, and `.loading` follows within the millisecond.
                  // Suppressing it is also what keeps a fully cached start —
                  // where the only callback is the terminal one — from
                  // flashing "downloading… 100%" over its "loading…".
                  percent < 100
            else { return }
            onPhase(.downloading(percent: percent))
        }
    }

    /// Applies a new language setting from the Language submenu. Takes effect
    /// on the next utterance: actor isolation means it can only land between
    /// `transcribe` calls, never inside one.
    ///
    /// A monitored set the previous language is no longer part of drops the
    /// bias rather than carrying a stale prior into the new set.
    public func setLanguage(_ setting: LanguageSetting) {
        language = setting
        if let lastUsedLanguage, !setting.monitors(lastUsedLanguage) {
            self.lastUsedLanguage = nil
        }
    }

    public func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let plan = LanguagePlan.resolve(model: model, setting: language)
        let monitored = language.monitoredCodes ?? []
        let previous = lastUsedLanguage.flatMap { monitored.contains($0) ? $0 : nil }

        // Pass one. For every setting except a multi-language monitored set on
        // a multilingual model this is also the last one.
        let first = try await pass(audio, pipeline: pipeline,
                                   language: plan.language,
                                   detectLanguage: plan.detectLanguage)
        var chosen = first
        var decision = plan.detectLanguage ? "detected" : "fixed"

        if plan.refines {
            // Every branch below is wrapped so a refinement failure can only
            // cost accuracy, never the transcript: pass one already produced
            // text, and the contract is that transcription does not start
            // throwing where it used to return words.
            (chosen, decision) = await refine(
                audio, pipeline: pipeline, first: first,
                monitored: monitored, previous: previous)
        }

        let text = Self.sanitize(chosen.text)
        if let language = chosen.language, monitored.contains(language), !text.isEmpty {
            lastUsedLanguage = language
        }
        // Only when there was a language question to answer. An English-only
        // model has one possible answer, so the line would be a constant on
        // every utterance — and printing it would make this branch change the
        // observable behaviour of the default model, which is the one thing
        // it set out not to do.
        if let language = chosen.language, !model.isEnglishOnly {
            FileHandle.standardError.write(Data("  language: \(language) · \(decision)\n".utf8))
        }
        return text
    }

    /// The monitored-set refinement, adapted from `aivars/parrot` (MIT,
    /// © Andrew Jones): confine the detection to the languages the user says
    /// they speak, and prefer the one they were just speaking when the call is
    /// close.
    ///
    /// Two shapes, and each costs exactly one more decoder pass:
    ///
    /// - the detection landed **outside** the set: pick the best *monitored*
    ///   language and transcribe again pinned to it.
    /// - the detection landed **inside** the set but is not what the last
    ///   utterance used: transcribe again pinned to the last language and let
    ///   `LanguagePolicy.chooseLanguage` compare confidences, with the bias.
    ///
    /// ## Why there is no `detectLangauge` call here
    ///
    /// The design this is adapted from calls `WhisperKit.detectLangauge` in
    /// the first branch, to rank the monitored languages by probability. It is
    /// not worth its cost against this WhisperKit: `TextDecoder.detectLanguage`
    /// (TextDecoder.swift:697–703) fills `languageProbs` only from the tokens
    /// the greedy sampler actually emitted, so the table that comes back holds
    /// **one** language — the same top-1 answer pass one already reported —
    /// and never a distribution. `selectMonitoredLanguage` would score every
    /// monitored language at `-.infinity` and take its degradation path
    /// regardless. Measured on this machine the call costs ~500 ms of its own
    /// (it re-runs the mel and the encoder), which is a third of the whole
    /// utterance's latency spent to learn nothing.
    ///
    /// So the first branch below spells out what that degradation path
    /// reduces to — the previous language if it is still monitored, else the
    /// first one listed — rather than calling `selectMonitoredLanguage` with
    /// an empty table and looking like a ranking runs. The policy function
    /// keeps its ranking and its tests, ready for the day a real table exists.
    ///
    /// Anything that goes wrong returns pass one unchanged. Never throws.
    private func refine(_ audio: [Float], pipeline: WhisperKit, first: Pass,
                        monitored: [String], previous: String?) async -> (Pass, String) {
        do {
            if !monitored.contains(first.language ?? "") {
                // `LanguagePolicy.selectMonitoredLanguage(probabilities: [:],
                // detected: <unmonitored>, lastUsed: previous, monitored:)`
                // returns exactly this; see the note above for why it is not
                // called.
                guard let best = previous ?? monitored.first
                else { return (first, "detected") }
                let pinned = try await pass(audio, pipeline: pipeline,
                                            language: best, detectLanguage: false)
                return replacing(first, with: pinned,
                                 decision: first.language.map { "monitored, over \($0)" }
                                     ?? "monitored")
            }

            guard let alternativeLanguage = LanguagePolicy.comparisonLanguage(
                detected: first.language, lastUsed: previous, monitored: monitored)
            else { return (first, "detected") }

            let alternative = try await pass(audio, pipeline: pipeline,
                                             language: alternativeLanguage,
                                             detectLanguage: false)
            let winner = LanguagePolicy.chooseLanguage(
                detected: first.language, detectedScore: first.confidence,
                alternative: alternativeLanguage, alternativeScore: alternative.confidence,
                lastUsed: previous, monitored: monitored)
            if winner == first.language { return (first, "detected") }
            return replacing(first, with: alternative,
                             decision: first.language.map { "kept over \($0)" } ?? "kept")
        } catch {
            // The transcript from pass one is already in hand; a failed
            // refinement is a worse language guess, not a lost dictation.
            FileHandle.standardError.write(Data(
                "  language refinement failed (\(type(of: error))); keeping the first pass\n"
                    .utf8))
            return (first, "detected")
        }
    }

    /// Applies a refinement's result, unless doing so would lose the words.
    ///
    /// A refinement may only ever change *which language* an utterance was
    /// decoded as. It must never be the reason the utterance produces nothing:
    /// a pass pinned to the wrong language can come back as bracket tokens
    /// alone (`[BLANK_AUDIO]`, `(silence)`), which `sanitize` correctly strips
    /// to the empty string — and returning that over a first pass that had
    /// real words would lose a dictation the daemon had already transcribed.
    /// That is the one guarantee this project does not trade against
    /// accuracy, so it is enforced here rather than assumed from the
    /// confidence comparison. (`confidence` returns `-.infinity` for a pass
    /// with no segments at all, which covers *some* of this — but a pass can
    /// have segments, and therefore a finite score, and still sanitize away
    /// to nothing.)
    private func replacing(_ first: Pass, with candidate: Pass,
                           decision: String) -> (Pass, String) {
        Self.keepsTheWords(candidate, over: first)
            ? (candidate, decision)
            : (first, "detected — the \(candidate.language ?? "second") pass "
                + "transcribed nothing")
    }

    /// Whether `candidate` may replace `first` without losing the utterance:
    /// either it has words of its own, or `first` had none either.
    static func keepsTheWords(_ candidate: Pass, over first: Pass) -> Bool {
        !sanitize(candidate.text).isEmpty || sanitize(first.text).isEmpty
    }

    private func pass(_ audio: [Float], pipeline: WhisperKit,
                      language: String?, detectLanguage: Bool) async throws -> Pass {
        // `chunkingStrategy: .vad` is what makes a long dictation work.
        //
        // WhisperKit branches on this in `transcribe(audioArray:)`: with a
        // strategy it splits the audio on silence, with none it falls to a
        // branch whose own comment reads "audio is short enough to transcribe
        // in a single window" — which long audio is not. That branch is the
        // plain sliding-window loop, where a window that fails its own
        // thresholds contributes nothing and the words in it are simply gone.
        //
        // Costs nothing on short utterances: WhisperKit only consults the
        // strategy when the audio exceeds one window, so anything under 30
        // seconds takes the same path it always did.
        let options = DecodingOptions(language: language,
                                      detectLanguage: detectLanguage,
                                      chunkingStrategy: .vad)
        let results: [TranscriptionResult] = try await pipeline.transcribe(
            audioArray: audio, decodeOptions: options)
        return Pass(text: results.map(\.text).joined(separator: " "),
                    language: language ?? Self.dominantLanguage(in: results),
                    confidence: Self.confidence(results))
    }

    /// One decoding pass's result: what was said, in what language, and how
    /// sure the decoder was — the last of which is the only basis
    /// `LanguagePolicy.chooseLanguage` has for preferring one pass over
    /// another.
    ///
    /// Internal, not private, for the reason `LanguagePolicy` exists at all:
    /// the decisions taken over these values are the interesting part, and a
    /// decision a test cannot construct an input for is a decision nobody has
    /// checked.
    struct Pass {
        let text: String
        let language: String?
        let confidence: Float
    }

    /// The language most of the windows agreed on. WhisperKit reports one per
    /// result and a long dictation can be chunked into several.
    ///
    /// **Ties go to the earliest window.** `Dictionary.max(by:)` over the
    /// counts would answer nondeterministically — the iteration order of a
    /// `Dictionary` is not stable across runs — so a two-window dictation
    /// with one window each way could report a different language on
    /// identical audio. Scanning in result order and taking only a *strictly*
    /// greater count picks the first-appearing language on a tie, which is
    /// both deterministic and the better guess: the first window is the one
    /// Whisper's own detection ran on.
    static func dominantLanguage(in results: [TranscriptionResult]) -> String? {
        let languages = results.map { $0.language.lowercased() }.filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for language in languages { counts[language, default: 0] += 1 }

        var best: String?
        var bestCount = 0
        for language in languages where counts[language, default: 0] > bestCount {
            best = language
            bestCount = counts[language, default: 0]
        }
        return best
    }

    /// Duration-weighted mean log-probability across a pass's segments — the
    /// score `LanguagePolicy.chooseLanguage` compares.
    ///
    /// Weighted so a half-second segment cannot outvote a ten-second one, and
    /// `-.infinity` when there are no segments at all so a pass that decoded
    /// nothing loses every comparison rather than winning one on a default of
    /// zero. (That is a floor, not the whole guarantee — see
    /// `keepsTheWords`.)
    static func confidence(_ results: [TranscriptionResult]) -> Float {
        let segments = results.flatMap(\.segments)
        guard !segments.isEmpty else { return -.infinity }
        var weighted: Float = 0
        var total: Float = 0
        for segment in segments {
            let weight = max(segment.duration, 0.1)
            weighted += segment.avgLogprob * weight
            total += weight
        }
        return total > 0 ? weighted / total : -.infinity
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}

/// What `WhisperKitTranscriber.warmUp` is doing, for a caller with a screen.
///
/// Two phases and no third, because they are the two waits: a first run
/// fetches 1.5 GB over the network, and *every* run then hands the weights to
/// Core ML, which specialises and prewarms them. Nothing after that is worth
/// reporting — `warmUp` returning is the report.
public enum TranscriberWarmup: Equatable, Sendable {
    /// `nil` until the first percentage is known, which is not until the hub
    /// has answered with the file listing. See `warmUp` for why the percentage
    /// is file-count weighted rather than byte weighted.
    case downloading(percent: Int?)
    case loading
    /// The load has not returned in `WhisperWarmupPlan.specialisationThreshold`,
    /// which on a warm cache leaves one explanation: Core ML is compiling the
    /// model for the Neural Engine. Measured on an M3 Pro that is 141–187s for
    /// `whisper-large-v3-turbo` and 11.3s for `whisper-base.en`, once per
    /// (code-signing identity × model × macOS build) — and it is all or
    /// nothing, so a user who quits into the third minute buys nothing and
    /// starts over. Calling that "loading…" is what makes them quit.
    ///
    /// The user-visible strings say "once per macOS version" rather than
    /// naming all three components of that key; see
    /// `WhisperWarmupPlan.specialisationNotice` for why that is the claim that
    /// survives contact with a system update.
    case preparingNeuralEngine

    /// Whether `incoming` may replace `current` on the way to warm.
    ///
    /// Each report reaches the main actor on its own `Task`
    /// (`Task { @MainActor in warmup.setTranscriber(phase) }`) and those arrive
    /// unordered, so the daemon cannot simply assign what it is handed.
    ///
    /// ## The one that is not a straggler
    ///
    /// A `.downloading` arriving after `.loading` has two possible meanings and
    /// they want opposite treatment. It can be a hop left over from a download
    /// that has already finished — accept it and the pill shows a stale
    /// percentage until the load returns. Or it can be
    /// `WhisperWarmupPlan.attempt`'s **repair**: a model that passed `isPresent`
    /// but failed to load falls back to the hub, and the pill has been sitting
    /// on `.loading` since before the first attempt. Reject that one and an
    /// entire 1.6 GB re-download runs under the word "loading…", with no
    /// progress and no watchdog — the watchdog only starts once the download is
    /// over. Minutes of unexplained "loading…" is the exact failure this branch
    /// exists to remove.
    ///
    /// They are distinguishable. `.downloading(percent: nil)` is emitted once,
    /// synchronously, at the top of the hub branch and never again — the
    /// coalescer only ever emits whole percents — so it is the repair's
    /// signature, and it alone may reopen the download. Its percentages then
    /// flow through the `.downloading` → `.downloading` rule as usual. A
    /// stale hop, which always carries a number, still cannot walk the pill
    /// backwards.
    ///
    /// (If the repair's own opening frame is itself delayed behind one of its
    /// percentages, that percentage is dropped and the next one is shown: one
    /// percent of lag, self-healing, against a rule that cannot mistake a
    /// straggler for a repair.)
    public static func advances(from current: TranscriberWarmup?,
                                to incoming: TranscriberWarmup?) -> Bool {
        // Warm is the end. Reopening it would put the gate back down behind a
        // recording that has already started.
        guard let current else { return false }
        guard let incoming else { return true }
        switch (current, incoming) {
        case (.downloading(let now), .downloading(let next)):
            guard let next else { return false }
            guard let now else { return true }
            return next > now
        case (.downloading, _): return true
        // The repair, from either of the two phases a failed local load can
        // have been in when it threw.
        case (.loading, .downloading(nil)),
             (.preparingNeuralEngine, .downloading(nil)):
            return true
        case (.loading, .downloading): return false
        case (.loading, .loading): return false
        case (.loading, .preparingNeuralEngine): return true
        case (.preparingNeuralEngine, _): return false
        }
    }
}
