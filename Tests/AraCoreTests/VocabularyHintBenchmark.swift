import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import AraCore

/// What feeding the dictionary to Whisper's decoder actually costs and risks.
///
/// The vocabulary-hint change biases decoding with `promptTokens` built from
/// the dictionary's canonical spellings. That is a real recognition win, and it
/// carries three risks worth measuring rather than reasoning about:
///
/// 1. **Language.** The hints are global. An English-canonical prompt against
///    Polish speech biases the decoder — and Whisper's prompt influences
///    language detection, not only spelling. Ara's users dictate in Polish.
/// 2. **Leakage.** Whisper is known to emit prompt content as transcript on
///    short or near-silent audio. Ara *already* has short-utterance trouble —
///    see `EmptyDictation` — and "nothing" turning into "your dictionary typed
///    at the cursor" is a worse failure than the one it replaces.
/// 3. **Latency.** A non-empty prompt disables WhisperKit's prefill cache.
///
/// **Opt-in**, like its neighbours — it loads the 1.6 GB multilingual model:
///
/// ```
/// ARA_VOCAB_BENCH=1 swift test -c release --filter VocabularyHint
/// ```
///
/// Audio is synthesised by `say`, reusing `LanguageLatencyBenchmark`'s
/// reasoning: reproducible, stated length, no megabyte fixture nobody reviews.
///
/// ## Result, 2026-08-04 — the change does not work
///
/// Measured on whisper-large-v3-turbo with the WhisperKit revision pinned in
/// Package.resolved:
///
/// | configuration                        | transcript                    |
/// |--------------------------------------|-------------------------------|
/// | no prompt (baseline)                 | "…to test flight this morning"|
/// | prompt, prefill on (**production**)  | **"" — empty**                |
/// | prompt, prefill on, language pinned  | **"" — empty**                |
/// | prompt (11 tokens), prefill on       | **"" — empty**                |
/// | prompt, prefill **off**              | "…to test flight this morning"|
///
/// So with WhisperKit's default `usePrefillPrompt: true` — what the change
/// ships — any non-empty dictionary empties every transcript. With prefill off
/// the prompt is *silently ignored*: `TextDecoder.prefillDecoderInputs` builds
/// the prompt block only inside the `usePrefillPrompt` branch, so it never
/// reaches the decoder, and "TestFlight" in the prompt does not stop the
/// baseline mishearing "test flight". Broken one way, inert the other.
///
/// Special tokens are not the cause: WhisperKit already filters them itself
/// (`TextDecoder.swift`, `trimmedPromptTokens`), and filtering them at the call
/// site changes nothing.
@Suite("VocabularyHint", .serialized)
struct VocabularyHintBenchmark {
    /// A dictionary of the shape a real user builds: product names, jargon and
    /// proper nouns, all English, none of them Polish words. Exactly the case
    /// that would drag Polish decoding toward English if the bias is too
    /// strong.
    static let canonicals = [
        "RevenueCat", "SwiftUI", "WhisperKit", "TestFlight", "Xcode",
        "Karniej", "Silpho", "VidNotes", "Coldsmith", "Rewordly",
        "MoonLatte", "SignIt", "Conduit", "AminoQuiz", "Astro",
    ]

    static let polish = "Cześć, to jest test dyktowania po polsku. "
        + "Sprawdzam czy wykrywanie języka działa poprawnie."
    static let shortPolish = "Tak, jasne."
    static let english = "I pushed the build to TestFlight this morning."

    @Test("hints: language, leakage and latency")
    func measure() async throws {
        guard ProcessInfo.processInfo.environment["ARA_VOCAB_BENCH"] == "1" else { return }
        let model = try #require(ModelRegistry.find("whisper-large-v3-turbo"))
        let whisperKitID = try #require(model.whisperKitID)

        let plAudio = try LanguageLatencyBenchmark.synthesise(Self.polish, voice: "Zosia")
        let shortAudio = try LanguageLatencyBenchmark.synthesise(Self.shortPolish,
                                                                voice: "Zosia")
        let enAudio = try LanguageLatencyBenchmark.synthesise(Self.english,
                                                             voice: "Samantha")
        // Near-silence: the classic prompt-leak trigger. Not synthesised —
        // a buffer of nothing is exactly the input a mistimed hotkey produces.
        let silence = [Float](repeating: 0, count: 16_000)

        let pipeline = try await WhisperKit(
            WhisperKitConfig(model: whisperKitID, verbose: false,
                             prewarm: true, load: true))
        let hints = Self.canonicals
        let prompt = try #require(
            Self.promptTokens(for: hints, tokenizer: pipeline.tokenizer))
        print("prompt: \(prompt.count) tokens from \(hints.count) canonicals")

        // MARK: 1 — does an English prompt break Polish detection?

        let plBare = try await pipeline.detectLangauge(audioArray: plAudio)
        let plHinted = try await Self.transcribe(pipeline, plAudio, prompt: prompt,
                                                 detect: true)
        print("polish: bare detected \(plBare.language) · "
              + "hinted \(plHinted.language ?? "nil")")
        print("  hinted text: \(plHinted.text)")
        // The assertion this suite exists for, and the one whose absence let a
        // non-functional feature pass 594 unit tests: a hinted pass must still
        // return words. Measured on whisper-large-v3-turbo, WhisperKit 0.9.x,
        // it returns the empty string — see the suite's doc comment.
        #expect(!WhisperKitTranscriber.sanitize(plHinted.text)
            .trimmingCharacters(in: .whitespaces).isEmpty,
                "a decoder prompt emptied the transcript")
        #expect(plHinted.language == "pl",
                Comment(rawValue: "an English-canonical prompt pulled Polish "
                    + "detection to \(plHinted.language ?? "nil")"))

        let shortHinted = try await Self.transcribe(pipeline, shortAudio,
                                                    prompt: prompt, detect: true)
        print("short polish: \(shortHinted.language ?? "nil") · \(shortHinted.text)")

        // MARK: 2 — does the prompt leak into the transcript?

        for (label, audio) in [("silence", silence), ("short", shortAudio)] {
            let out = try await Self.transcribe(pipeline, audio, prompt: prompt,
                                                detect: true)
            let sanitised = WhisperKitTranscriber.sanitize(out.text)
            print("leak/\(label): \"\(sanitised)\"")
            let leaked = hints.filter { sanitised.localizedCaseInsensitiveContains($0) }
            #expect(leaked.isEmpty,
                    Comment(rawValue: "\(label) audio produced dictionary terms "
                        + "\(leaked) that were never spoken"))
        }

        // MARK: 3 — what does the disabled prefill cache cost?

        for (label, audio) in [("pl", plAudio), ("en", enAudio)] {
            let bare = try await Self.time {
                _ = try await Self.transcribe(pipeline, audio, prompt: nil, detect: true)
            }
            let hinted = try await Self.time {
                _ = try await Self.transcribe(pipeline, audio, prompt: prompt, detect: true)
            }
            print(String(format: "latency/%@: bare %.0f ms · hinted %.0f ms (%+.0f%%)",
                         label, bare, hinted, (hinted - bare) / bare * 100))
        }

        // MARK: 4 — does it actually help? The reason to take the change.

        let enBare = try await Self.transcribe(pipeline, enAudio, prompt: nil, detect: true)
        let enHinted = try await Self.transcribe(pipeline, enAudio, prompt: prompt,
                                                 detect: true)
        print("english bare:   \(enBare.text)")
        print("english hinted: \(enHinted.text)")
        #expect(!WhisperKitTranscriber.sanitize(enHinted.text)
            .trimmingCharacters(in: .whitespaces).isEmpty,
                "a decoder prompt emptied the transcript")
    }

    // MARK: - Harness

    /// The production prompt shape, duplicated here because the real one is a
    /// `private static` on the actor. Kept identical on purpose: a benchmark
    /// measuring a different prompt than production ships measures nothing.
    private static func promptTokens(for hints: [String],
                                     tokenizer: WhisperTokenizer?) -> [Int]? {
        guard !hints.isEmpty, let tokenizer else { return nil }
        return Array(tokenizer.encode(text: hints.joined(separator: ", ") + ".")
            .suffix(111))
    }

    private static func transcribe(
        _ pipeline: WhisperKit, _ audio: [Float], prompt: [Int]?, detect: Bool
    ) async throws -> (text: String, language: String?) {
        let results: [TranscriptionResult] = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: DecodingOptions(detectLanguage: detect,
                                           promptTokens: prompt))
        return (results.map(\.text).joined(separator: " "),
                results.first?.language)
    }

    private static func time(_ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }
}
