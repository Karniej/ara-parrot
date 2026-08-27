import Foundation

/// Why an utterance produced no text — PLACEHOLDER DOC.
public enum EmptyDictation: Equatable, Sendable {
    case noAudio
    case silence
    case tooShort(lateStart: Bool)
    case unrecognised

    /// Whisper's floor, in seconds.
    public static let minimumSeconds: Double = 1.0

    /// The RMS below which a buffer carries no sound.
    public static let silenceRMS: Float = 0.005

    /// Leading silence worth mentioning.
    public static let lateStartSeconds: Double = 0.25

    public var message: String {
        switch self {
        case .noAudio: return "no audio captured"
        case .silence: return "only silence — check your microphone"
        case .tooShort(lateStart: false): return "too short — hold the key while you speak"
        case .tooShort(lateStart: true): return "too short — your mic starts late; hold the key longer"
        case .unrecognised: return "couldn't make out any words"
        }
    }

    public var reason: String {
        switch self {
        case .noAudio: return "no audio captured"
        case .silence: return "silence"
        case .tooShort(lateStart: false): return "too short"
        case .tooShort(lateStart: true): return "too short, late start"
        case .unrecognised: return "nothing recognised"
        }
    }

    /// Why this utterance produced nothing worth typing, or `nil` when it did.
    ///
    /// ## The audio outranks the transcript
    ///
    /// Whisper does not answer silence with silence. It was trained on
    /// captioned video, so a buffer with nothing in it comes back as "Thank
    /// you." or "Thanks for watching!" — confident, well-formed, and entirely
    /// invented. Reported from use as ara saying thank you to a recording
    /// nobody spoke into.
    ///
    /// This used to open with a guard that returned `nil` for any non-blank
    /// transcript, which meant every check below it — including the rms that
    /// says the microphone heard nothing — was only ever reached when Whisper
    /// had already admitted it had nothing. The moment it invented something
    /// instead, the evidence was skipped and the invention was typed.
    ///
    /// So the sound comes first. If the buffer carried none, anything derived
    /// from it was made up, however plausible it reads.
    ///
    /// ## Why not a list of known phrases
    ///
    /// Matching "thank you" and its friends would need one list per language
    /// Whisper speaks, would fail on the next wording it invents, and would
    /// eventually reject a user who really did dictate "thank you" into a live
    /// microphone. The rms is language-neutral and describes the recording
    /// rather than guessing at the words.
    public static func diagnose(sampleCount: Int, seconds: Double, rms: Float,
                                leadingSilence: Double,
                                transcript: String) -> EmptyDictation? {
        if sampleCount == 0 { return .noAudio }
        if rms < silenceRMS { return .silence }
        guard transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if seconds < minimumSeconds {
            return .tooShort(lateStart: leadingSilence >= lateStartSeconds)
        }
        return .unrecognised
    }

    /// Seconds of silence before the first sound.
    public static func leadingSilence(_ samples: [Float],
                                      sampleRate: Double) -> Double {
        guard !samples.isEmpty, sampleRate > 0 else { return 0 }
        let frame = max(1, Int(sampleRate / 100))   // 10 ms
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            var sum: Double = 0
            for i in index..<end { sum += Double(samples[i] * samples[i]) }
            if (sum / Double(end - index)).squareRoot() >= Double(silenceRMS) {
                break
            }
            index = end
        }
        return Double(index) / sampleRate
    }
}
