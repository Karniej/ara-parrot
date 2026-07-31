import Foundation
import WhisperKit

public actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
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
        self.modelID = model.id
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
        pipeline = try await WhisperWarmupPlan.attempt(from: source, onRepair: { _ in
            FileHandle.standardError.write(Data(
                "\(id) did not load from disk; re-checking the download...\n".utf8))
        }) { source in
            try await load(from: source, variant: whisperKitID, onPhase: onPhase)
        }
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    /// Resolves a `ModelSource` to a folder and builds the pipeline from it.
    private func load(
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
                                      verbose: false, prewarm: true, load: true,
                                      download: false)
        return try await WhisperKit(config)
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
        let options = DecodingOptions(language: language, detectLanguage: detectLanguage)
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
}
