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
    public func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
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
        if let language = chosen.language {
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
    /// utterance's latency spent to learn nothing. The probabilities argument
    /// stays, empty and documented, so the ranking works the day WhisperKit
    /// returns a real table.
    ///
    /// Anything that goes wrong returns pass one unchanged. Never throws.
    private func refine(_ audio: [Float], pipeline: WhisperKit, first: Pass,
                        monitored: [String], previous: String?) async -> (Pass, String) {
        do {
            if !monitored.contains(first.language ?? "") {
                guard let best = LanguagePolicy.selectMonitoredLanguage(
                    probabilities: [:],
                    detected: first.language,
                    lastUsed: previous,
                    monitored: monitored)
                else { return (first, "detected") }
                let pinned = try await pass(audio, pipeline: pipeline,
                                            language: best, detectLanguage: false)
                return (pinned, first.language.map { "monitored, over \($0)" }
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
            return (alternative, first.language.map { "kept over \($0)" } ?? "kept")
        } catch {
            // The transcript from pass one is already in hand; a failed
            // refinement is a worse language guess, not a lost dictation.
            FileHandle.standardError.write(Data(
                "  language refinement failed (\(type(of: error))); keeping the first pass\n"
                    .utf8))
            return (first, "detected")
        }
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
    private struct Pass {
        let text: String
        let language: String?
        let confidence: Float
    }

    /// The language most of the windows agreed on. WhisperKit reports one per
    /// result and a long dictation can be chunked into several.
    private static func dominantLanguage(in results: [TranscriptionResult]) -> String? {
        let languages = results.map { $0.language.lowercased() }.filter { !$0.isEmpty }
        return Dictionary(grouping: languages, by: { $0 })
            .mapValues(\.count)
            .max { $0.value < $1.value }?
            .key
    }

    /// Mean log-probability per second of speech. Duration-weighted so a
    /// half-second segment cannot outvote a ten-second one, and `-.infinity`
    /// for no segments at all so an empty pass loses every comparison rather
    /// than winning one on a default of zero.
    private static func confidence(_ results: [TranscriptionResult]) -> Float {
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
