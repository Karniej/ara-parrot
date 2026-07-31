import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import AraCore

/// The measurement behind the latency numbers in `docs/KNOWN-ISSUES.md` and
/// the README, kept in the repository so they can be re-taken rather than
/// trusted — `MLXLatencyBenchmark`'s contract, for the transcription side.
///
/// **Opt-in**: it loads the 1.6 GB multilingual model and runs a dozen real
/// decoder passes, so it is inert unless `ARA_LANG_BENCH=1` is set:
///
/// ```
/// ARA_LANG_BENCH=1 swift test --filter LanguageLatency
/// ```
///
/// after `ara models download whisper-large-v3-turbo`.
///
/// The audio is synthesised by `say` — Zosia for Polish, Samantha for English
/// — rather than committed as a fixture: a WAV in the repository is a
/// megabyte nobody reviews, and text-to-speech gives a clean, reproducible
/// utterance of a stated length. It is *not* a substitute for real dictation
/// when judging accuracy; it is a fixed-cost audio buffer for judging time.
@Suite("LanguageLatency")
struct LanguageLatencyBenchmark {
    static let polish = "Cześć, to jest test dyktowania po polsku. "
        + "Sprawdzam czy wykrywanie języka działa poprawnie."
    static let english = "Hello, this is a dictation test in English. "
        + "I am checking whether language detection works correctly."
    /// The short-utterance case: detection sees one mostly-silent window.
    static let shortPolish = "Tak, jasne."

    @Test("detection and refinement cost, on the large multilingual model")
    func measure() async throws {
        guard ProcessInfo.processInfo.environment["ARA_LANG_BENCH"] == "1" else { return }
        let model = try #require(ModelRegistry.find("whisper-large-v3-turbo"))
        let whisperKitID = try #require(model.whisperKitID)

        let plAudio = try Self.synthesise(Self.polish, voice: "Zosia")
        let enAudio = try Self.synthesise(Self.english, voice: "Samantha")
        let shortAudio = try Self.synthesise(Self.shortPolish, voice: "Zosia")
        print(String(format: "audio: pl %.2fs · en %.2fs · short %.2fs",
                     Double(plAudio.count) / 16_000,
                     Double(enAudio.count) / 16_000,
                     Double(shortAudio.count) / 16_000))

        let pipeline = try await WhisperKit(
            WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true))

        // One untimed pass so the first-run compilation and cache warm-up do
        // not land on the first measurement.
        _ = try await pipeline.transcribe(audioArray: plAudio,
                                          decodeOptions: DecodingOptions(language: "pl",
                                                                         detectLanguage: false))

        // The bug itself, demonstrated rather than argued: WhisperKit's own
        // defaults transcribe Polish audio as English, because
        // `detectLanguage` defaults to false (Configurations.swift:226) and
        // the detection branch (TranscribeTask.swift:312) is never taken.
        let defaults: [TranscriptionResult] = try await pipeline.transcribe(audioArray: plAudio)
        print("today's defaults → language \(defaults.first?.language ?? "?"): "
            + (defaults.map(\.text).joined()))

        var timings: [(String, Duration, String)] = []
        func time(_ label: String, _ body: () async throws -> (String, String)) async rethrows {
            let start = ContinuousClock.now
            let (language, text) = try await body()
            timings.append((label, ContinuousClock.now - start, "\(language): \(text)"))
        }

        try await time("pinned pl (1 pass)") {
            let r: [TranscriptionResult] = try await pipeline.transcribe(
                audioArray: plAudio,
                decodeOptions: DecodingOptions(language: "pl", detectLanguage: false))
            return (r.first?.language ?? "?", r.map(\.text).joined())
        }
        try await time("auto (1 pass + detection)") {
            let r: [TranscriptionResult] = try await pipeline.transcribe(
                audioArray: plAudio,
                decodeOptions: DecodingOptions(language: nil, detectLanguage: true))
            return (r.first?.language ?? "?", r.map(\.text).joined())
        }
        // What the daemon did before this branch, stated explicitly: no
        // detection, so the decoder is prefilled with English. Whether that
        // *ruins* a transcript depends on the audio — a clean, unambiguous
        // utterance often survives it — which is why the defect is stated as
        // "the language is not detected" and not as "the text is English".
        try await time("pinned en on Polish audio") {
            let r: [TranscriptionResult] = try await pipeline.transcribe(
                audioArray: plAudio,
                decodeOptions: DecodingOptions(language: "en", detectLanguage: false))
            return (r.first?.language ?? "?", r.map(\.text).joined())
        }
        try await time("pinned en on short Polish") {
            let r: [TranscriptionResult] = try await pipeline.transcribe(
                audioArray: shortAudio,
                decodeOptions: DecodingOptions(language: "en", detectLanguage: false))
            return (r.first?.language ?? "?", r.map(\.text).joined())
        }
        try await time("detectLangauge() alone") {
            let d = try await pipeline.detectLangauge(audioArray: plAudio)
            return (d.language, "\(d.langProbs.count) languages scored")
        }
        try await time("short utterance, auto") {
            let r: [TranscriptionResult] = try await pipeline.transcribe(
                audioArray: shortAudio,
                decodeOptions: DecodingOptions(language: nil, detectLanguage: true))
            return (r.first?.language ?? "?", r.map(\.text).joined())
        }
        try await time("english, auto") {
            let r: [TranscriptionResult] = try await pipeline.transcribe(
                audioArray: enAudio,
                decodeOptions: DecodingOptions(language: nil, detectLanguage: true))
            return (r.first?.language ?? "?", r.map(\.text).joined())
        }

        for (label, elapsed, detail) in timings {
            print(String(format: "%-28s %7.0f ms  %@", (label as NSString).utf8String!,
                         Double(elapsed.components.attoseconds) / 1e15
                             + Double(elapsed.components.seconds) * 1000,
                         detail))
        }

        // The one correctness assertion the synthetic audio can carry: with
        // detection on, Polish audio comes back as Polish.
        let detected = try await pipeline.detectLangauge(audioArray: plAudio)
        #expect(detected.language.lowercased() == "pl")
    }

    /// Synthesises speech into the 16 kHz mono float array Whisper wants.
    /// `say` writes exactly that format, so nothing has to be resampled.
    static func synthesise(_ text: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-lang-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "--data-format=LEF32@16000",
                             "--file-format=WAVE", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()

        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
