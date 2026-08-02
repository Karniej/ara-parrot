import Foundation
import Testing
@testable import AraCore

@Suite("EmptyDictation")
struct EmptyDictationTests {
    // MARK: - It fires only when there is nothing to inject

    @Test("a transcript with words is not a diagnosis")
    func wordsAreNotADiagnosis() {
        // Deliberately alongside audio that would otherwise be diagnosed: the
        // guard's whole obligation is that it cannot take a transcript away.
        #expect(EmptyDictation.diagnose(sampleCount: 12_000, seconds: 0.75,
                                        rms: 0.0, leadingSilence: 0.7,
                                        transcript: "hello") == nil)
    }

    @Test("whitespace is not words")
    func whitespaceIsEmpty() {
        #expect(EmptyDictation.diagnose(sampleCount: 48_000, seconds: 3,
                                        rms: 0.08, leadingSilence: 0,
                                        transcript: " \n ")
                == .unrecognised)
    }

    // MARK: - The four cases

    @Test("no samples at all")
    func noAudio() {
        #expect(EmptyDictation.diagnose(sampleCount: 0, seconds: 0, rms: 0,
                                        leadingSilence: 0, transcript: "")
                == .noAudio)
    }

    /// `○ captured 2.30s · rms 0.000 → 0.84s · 0 chars` — long enough, and
    /// nothing in it.
    @Test("audio that carries no sound")
    func silence() {
        #expect(EmptyDictation.diagnose(sampleCount: 36_800, seconds: 2.30,
                                        rms: 0.000, leadingSilence: 2.30,
                                        transcript: "")
                == .silence)
    }

    /// The line this whole defect is about: `○ captured 0.77s · rms 0.142`.
    /// Loud, unambiguous speech, and Whisper returned nothing.
    @Test("loud but too short")
    func tooShort() {
        #expect(EmptyDictation.diagnose(sampleCount: 12_320, seconds: 0.77,
                                        rms: 0.142, leadingSilence: 0.04,
                                        transcript: "")
                == .tooShort(lateStart: false))
    }

    @Test("too short, and most of it was the microphone waking up")
    func tooShortWithLateStart() {
        #expect(EmptyDictation.diagnose(sampleCount: 12_320, seconds: 0.77,
                                        rms: 0.142, leadingSilence: 0.33,
                                        transcript: "")
                == .tooShort(lateStart: true))
    }

    @Test("good audio, and no words came back")
    func unrecognised() {
        #expect(EmptyDictation.diagnose(sampleCount: 48_000, seconds: 3.0,
                                        rms: 0.075, leadingSilence: 0.1,
                                        transcript: "")
                == .unrecognised)
    }

    // MARK: - Precedence

    @Test("silence outranks too-short")
    func silenceOutranksTooShort() {
        // Half a second of digital zeros is both, and "hold the key longer"
        // is the wrong advice for a microphone that is delivering nothing.
        #expect(EmptyDictation.diagnose(sampleCount: 8_000, seconds: 0.5,
                                        rms: 0.0, leadingSilence: 0.5,
                                        transcript: "")
                == .silence)
    }

    @Test("no audio outranks everything")
    func noAudioOutranksEverything() {
        #expect(EmptyDictation.diagnose(sampleCount: 0, seconds: 0.5, rms: 0.2,
                                        leadingSilence: 0, transcript: "")
                == .noAudio)
    }

    // MARK: - What the user is told

    @Test("every case says something different, and says something")
    func messagesAreDistinct() {
        let all: [EmptyDictation] = [.noAudio, .silence, .tooShort(lateStart: false),
                                     .tooShort(lateStart: true), .unrecognised]
        let messages = all.map(\.message)
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == all.count)
    }

    @Test("the too-short message is the actionable one")
    func tooShortIsActionable() {
        #expect(EmptyDictation.tooShort(lateStart: false).message.contains("hold"))
        #expect(EmptyDictation.tooShort(lateStart: true).message.contains("hold"))
    }

    /// The log line is not the pill: stderr may be a file that outlives the
    /// session, so it carries the numbers and never the transcript.
    @Test("the log reason names the evidence")
    func logReason() {
        #expect(EmptyDictation.tooShort(lateStart: false).reason == "too short")
        #expect(EmptyDictation.noAudio.reason == "no audio captured")
    }

    // MARK: - Leading silence

    @Test("silence in front of speech is measured")
    func leadingSilenceRun() {
        var samples = [Float](repeating: 0, count: 4_800)   // 0.30 s at 16 kHz
        samples += (0..<16_000).map { Float(0.2 * sin(Double($0) * 0.1)) }
        let measured = EmptyDictation.leadingSilence(samples,
                                                     sampleRate: 16_000)
        #expect(abs(measured - 0.30) < 0.02)
    }

    @Test("speech from the first sample has no leading silence")
    func noLeadingSilence() {
        let samples = (0..<16_000).map { Float(0.2 * sin(Double($0) * 0.1)) }
        #expect(EmptyDictation.leadingSilence(samples, sampleRate: 16_000) == 0)
    }

    @Test("a buffer that is silent throughout is silent throughout")
    func allSilence() {
        let samples = [Float](repeating: 0, count: 16_000)
        #expect(abs(EmptyDictation.leadingSilence(samples, sampleRate: 16_000) - 1)
                < 0.02)
    }

    @Test("no samples, no leading silence")
    func emptyBuffer() {
        #expect(EmptyDictation.leadingSilence([], sampleRate: 16_000) == 0)
    }
}
