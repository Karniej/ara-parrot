import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import AraCore

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Parakeet TDT v3 against the Whisper model ara actually runs, on this
/// machine, in one session.
///
/// **Opt-in**: it downloads and loads real Core ML models, so it is inert
/// unless `ARA_PARAKEET_BENCH=1` is set.
///
/// ```
/// ARA_PARAKEET_BENCH=1 swift test --filter Parakeet
/// ```
///
/// ## Why the audio is synthesized by `say`
///
/// The existing `WhisperLoadBenchmark` transcribes a sine wave, which is fine
/// for timing a load and useless for anything else — neither model has words
/// to find, and a model that gives up early looks fast. Real dictation would
/// be better still, but a user's own recordings are private and a committed
/// audio fixture is a binary in the repository that nobody can review.
///
/// `say` is on every Mac, produces genuine speech with known text, and makes
/// the run reproducible on someone else's machine. It is cleaner than either
/// model's training data, so absolute accuracy here means little — what it
/// supports is the comparison, which is the question being asked.
///
/// ## What is measured
///
/// Load time and per-utterance time, at three lengths. Both models are given
/// the same samples in the same process, and the first transcription of each
/// is reported separately: a first pass builds lazy state that never recurs,
/// and comparing one model's first pass against another's steady state is how
/// a compute unit gets credited with a win it does not have. That mistake was
/// made once already in this project's history and reversed a decision.
@Suite("Parakeet", .serialized)
struct ParakeetBenchmark {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ARA_PARAKEET_BENCH"] == "1"
    }

    /// Three lengths, because dictation is not one shape: a short command, a
    /// sentence, and the kind of long paragraph that showed up in the field
    /// reports behind `InjectionPolicy`.
    static let utterances: [(name: String, text: String)] = [
        ("short", "open the terminal and run the tests"),
        ("medium", "The overlay pill shows what the daemon is doing while it "
            + "loads, and the menu bar carries the same state for anyone who "
            + "is not looking at the screen."),
        ("long", "I just found out about the issue where the browser signs off "
            + "from my account. I was logged out everywhere, but not from the "
            + "web app, and it looked like I was still logged in even though I "
            + "could not see any of my transcribed videos in my library. The "
            + "transcript arrived with one whole chunk moved to the end, which "
            + "is what sent us looking at the keyboard event ordering in the "
            + "first place, and eventually to pasting instead of typing."),
    ]

    static func ms(_ d: Duration) -> String {
        String(format: "%7.0f", Double(d.components.attoseconds) / 1e15
            + Double(d.components.seconds) * 1000)
    }

    /// Renders `text` to 16 kHz mono Float32 through `say`.
    ///
    /// `--file-format=WAVE --data-format=LEI16@16000` asks for exactly what
    /// both models want, so there is no resampling step to get wrong. The AIFF
    /// form was tried first and `say` rejected it with "Opening output file
    /// failed: fmt?" — while still exiting 0 and leaving an empty file behind,
    /// which is why the exit status is not trusted here and the bytes are
    /// checked instead.
    static func speech(_ text: String) throws -> [Float] {
        let wav = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ara-bench-\(abs(text.hashValue)).wav")
        if (try? Data(contentsOf: wav))?.isEmpty != false {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", wav.path, "--file-format=WAVE",
                             "--data-format=LEI16@16000", text]
            try say.run()
            say.waitUntilExit()
        }
        guard let written = try? Data(contentsOf: wav), !written.isEmpty else {
            throw BenchError.noAudio(wav.path)
        }

        // `AVAudioFile.processingFormat` is float32 regardless of what is on
        // disk, so reading gives the samples both models take, at the rate
        // `say` was asked for.
        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length))
        else { throw BenchError.noAudio(wav.path) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw BenchError.noAudio(wav.path)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    enum BenchError: Error, CustomStringConvertible {
        case noAudio(String)
        var description: String {
            switch self {
            case .noAudio(let path): return "say produced no audio at \(path)"
            }
        }
    }

    static func seconds(_ samples: [Float]) -> Double {
        Double(samples.count) / 16_000
    }

    #if canImport(FluidAudio)
    @Test("Parakeet TDT v3 — load, then transcribe at three lengths")
    func parakeet() async throws {
        guard Self.enabled else { return }

        print("\n=== Parakeet TDT v3 (FluidAudio, CoreML/ANE) ===")
        let t0 = ContinuousClock.now
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        print("  \(Self.ms(ContinuousClock.now - t0)) ms  download + load")

        for (name, text) in Self.utterances {
            let samples = try Self.speech(text)
            guard !samples.isEmpty else {
                Issue.record("no audio for \(name)")
                continue
            }
            // Twice. The first pass carries one-off costs; the second is what
            // an ordinary utterance costs. Fresh decoder state per round. A TDT decoder carries state
            // across calls so a stream continues where it left off; reusing it
            // between two unrelated utterances would measure something nobody
            // does.
            for round in 1...2 {
                var decoder = try TdtDecoderState()
                let t = ContinuousClock.now
                let result = try await manager.transcribe(samples, decoderState: &decoder)
                let took = ContinuousClock.now - t
                let audio = Self.seconds(samples)
                print("  \(Self.ms(took)) ms  \(name) round \(round)"
                    + String(format: "  (%.1fs audio, %.0fx realtime)",
                             audio, audio / (Double(took.components.attoseconds) / 1e18
                                             + Double(took.components.seconds))))
                if round == 2 { print("      → \(result.text)") }
            }
        }
    }
    #endif

    /// The same audio through the model ara ships, in the same session.
    @Test("whisper-large-v3-turbo — the same audio, the same session")
    func whisper() async throws {
        guard Self.enabled else { return }
        let model = ModelRegistry.find("whisper-large-v3-turbo")!
        try #require(WhisperModelStore.isPresent(model), "download \(model.id) first")

        print("\n=== whisper-large-v3-turbo (WhisperKit, as shipped) ===")
        let t0 = ContinuousClock.now
        let transcriber = WhisperKitTranscriber(model: model)
        try await transcriber.warmUp()
        print("  \(Self.ms(ContinuousClock.now - t0)) ms  load")

        for (name, text) in Self.utterances {
            let samples = try Self.speech(text)
            guard !samples.isEmpty else {
                Issue.record("no audio for \(name)")
                continue
            }
            for round in 1...2 {
                let t = ContinuousClock.now
                let out = try await transcriber.transcribe(samples)
                let took = ContinuousClock.now - t
                let audio = Self.seconds(samples)
                print("  \(Self.ms(took)) ms  \(name) round \(round)"
                    + String(format: "  (%.1fs audio, %.0fx realtime)",
                             audio, audio / (Double(took.components.attoseconds) / 1e18
                                             + Double(took.components.seconds))))
                if round == 2 { print("      → \(out)") }
            }
        }
    }
}
