import AVFoundation
import Foundation
import Testing
@testable import AraCore

/// What Whisper does with an utterance shorter than a second, and whether
/// padding it with silence rescues one — the measurement behind
/// `EmptyDictation`'s threshold and behind the decision *not* to pad.
///
/// **Opt-in**: it loads a real Core ML model and shells out to `say` to
/// synthesize speech, so it is inert unless `ARA_SHORT_BENCH=1` is set:
///
/// ```
/// ARA_SHORT_BENCH=1 swift test --filter ShortUtterance
/// ```
///
/// `ARA_SHORT_MODEL` picks the model id (default `whisper-base.en`, the
/// recommended one). `say` is not the user's voice — it is cleaner than any
/// microphone and has no room in it — which makes it the *favourable* case: a
/// duration that fails here fails harder on real audio.
@Suite("ShortUtterance", .serialized)
struct ShortUtteranceBenchmark {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ARA_SHORT_BENCH"] == "1"
    }

    static var model: TranscriptionModel {
        let id = ProcessInfo.processInfo.environment["ARA_SHORT_MODEL"]
            ?? "whisper-base.en"
        return ModelRegistry.find(id)!
    }

    static let sampleRate: Double = 16_000

    /// Synthesizes `text` and returns it as the 16 kHz mono float buffer the
    /// capture path produces. `--data-format=LEF32@16000` asks `say` for
    /// exactly that layout, so nothing is resampled on the way in.
    static func speech(_ text: String, rate: Int? = nil) throws -> [Float] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ara-short-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var arguments = ["-o", url.path, "--data-format=LEF32@16000"]
        if let rate { arguments += ["-r", String(rate)] }
        arguments.append(text)
        say.arguments = arguments
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames)
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel,
                                         count: Int(buffer.frameLength)))
    }

    static func seconds(_ samples: [Float]) -> Double {
        Double(samples.count) / sampleRate
    }

    /// The first `seconds` of a clip — a hotkey released early, which is what
    /// a 0.77 s capture of a longer sentence actually is.
    static func head(_ samples: [Float], seconds: Double) -> [Float] {
        Array(samples.prefix(Int(seconds * sampleRate)))
    }

    /// Digital silence, front and back. The two padding shapes worth trying:
    /// a tail pad gives the decoder a window to settle in, and a lead pad
    /// moves the speech off the very first frame.
    static func padded(_ samples: [Float], lead: Double, total: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        out += samples
        let target = Int(total * sampleRate)
        if out.count < target {
            out += [Float](repeating: 0, count: target - out.count)
        }
        return out
    }

    @Test("short utterances, with and without padding")
    func measure() async throws {
        guard Self.enabled else { return }
        let model = Self.model
        try #require(WhisperModelStore.isPresent(model),
                     "run `ara models download \(model.id)` first")
        let transcriber = WhisperKitTranscriber(model: model)
        try await transcriber.warmUp()

        // A short phrase at its own natural length, the same phrase truncated
        // to the durations the user's log shows, and a longer one for the
        // control.
        let short = try Self.speech("yes")
        let phrase = try Self.speech("send it after the meeting")
        let cases: [(label: String, audio: [Float])] = [
            ("\"yes\", whole", short),
            ("phrase, first 0.40 s", Self.head(phrase, seconds: 0.40)),
            ("phrase, first 0.60 s", Self.head(phrase, seconds: 0.60)),
            ("phrase, first 0.77 s", Self.head(phrase, seconds: 0.77)),
            ("phrase, first 1.00 s", Self.head(phrase, seconds: 1.00)),
            ("phrase, first 1.50 s", Self.head(phrase, seconds: 1.50)),
            ("phrase, whole", phrase),
        ]

        print("model: \(model.id)")
        for item in cases {
            let conditions: [(String, [Float])] = [
                ("raw          ", item.audio),
                ("tail→1.5s    ", Self.padded(item.audio, lead: 0, total: 1.5)),
                ("tail→3.0s    ", Self.padded(item.audio, lead: 0, total: 3.0)),
                ("0.25s lead→3s", Self.padded(item.audio, lead: 0.25, total: 3.0)),
            ]
            print(String(format: "%@ (%.2fs, rms %.3f)",
                         item.label.padding(toLength: 24, withPad: " ", startingAt: 0),
                         Self.seconds(item.audio), computeRMS(item.audio)))
            for (label, audio) in conditions {
                let start = ContinuousClock.now
                let text = try await transcriber.transcribe(audio)
                let ms = Double((ContinuousClock.now - start)
                    .components.attoseconds) / 1e15
                    + Double((ContinuousClock.now - start).components.seconds) * 1000
                print(String(format: "    %@ %5.0f ms  %@", label, ms,
                             text.isEmpty ? "∅" : "\"\(text)\""))
            }
        }
    }
}
