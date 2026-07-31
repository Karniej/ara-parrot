import Foundation
import Testing
import WhisperKit
@testable import AraCore

/// The decisions `WhisperKitTranscriber` takes *over* a decoding pass's
/// result, reachable without a model, a microphone or 1.6 GB of weights —
/// which is the whole reason they are functions over values rather than lines
/// inside `transcribe`.
@Suite("TranscriberPass")
struct TranscriberPassTests {
    private typealias Pass = WhisperKitTranscriber.Pass

    private func result(language: String,
                        text: String = "hello",
                        segments: [TranscriptionSegment] = []) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: segments, language: language,
                            timings: TranscriptionTimings())
    }

    private func segment(start: Float, end: Float, avgLogprob: Float) -> TranscriptionSegment {
        TranscriptionSegment(id: 0, seek: 0, start: start, end: end, text: "x",
                             tokens: [], avgLogprob: avgLogprob)
    }

    // MARK: - keepsTheWords: the guarantee, not the preference

    /// The one thing a refinement may never do. A pass pinned to the wrong
    /// language can come back as bracket tokens alone, which `sanitize`
    /// correctly strips to nothing — and returning that over a first pass
    /// that had real words would lose an utterance the daemon had already
    /// transcribed.
    @Test("a refinement that transcribed nothing cannot replace one that did")
    func emptyCannotReplaceWords() {
        let words = Pass(text: "cześć, to jest test", language: "pl", confidence: -0.4)
        let nothing = Pass(text: "", language: "en", confidence: -0.1)
        #expect(!WhisperKitTranscriber.keepsTheWords(nothing, over: words))
    }

    /// The subtle version, and the one the confidence floor does *not* cover:
    /// a pass with segments has a finite score, so nothing in the comparison
    /// stops it — but everything it produced is stripped by `sanitize`.
    @Test("a refinement that sanitizes away to nothing cannot replace words either")
    func sanitizedEmptyCannotReplaceWords() {
        let words = Pass(text: "real words here", language: "pl", confidence: -0.9)
        let brackets = Pass(text: "[BLANK_AUDIO] (silence)", language: "en", confidence: -0.1)
        #expect(WhisperKitTranscriber.sanitize(brackets.text).isEmpty)
        #expect(!WhisperKitTranscriber.keepsTheWords(brackets, over: words))
    }

    @Test("a refinement with words of its own may replace")
    func wordsMayReplace() {
        let first = Pass(text: "hello", language: "en", confidence: -0.4)
        let second = Pass(text: "cześć", language: "pl", confidence: -0.2)
        #expect(WhisperKitTranscriber.keepsTheWords(second, over: first))
    }

    /// Silence is still silence. When the first pass produced nothing either,
    /// there is no transcript to protect and the refinement's answer — also
    /// nothing — is not worse.
    @Test("when neither pass produced words, the refinement stands")
    func bothEmpty() {
        let nothing = Pass(text: "", language: "en", confidence: -.infinity)
        let alsoNothing = Pass(text: "[BLANK_AUDIO]", language: "pl", confidence: -.infinity)
        #expect(WhisperKitTranscriber.keepsTheWords(alsoNothing, over: nothing))
    }

    // MARK: - dominantLanguage

    @Test("no results, or results with no language, answer nothing")
    func dominantEmpty() {
        #expect(WhisperKitTranscriber.dominantLanguage(in: []) == nil)
        #expect(WhisperKitTranscriber.dominantLanguage(in: [result(language: "")]) == nil)
    }

    @Test("the language most windows agreed on wins")
    func dominantMajority() {
        let results = [result(language: "en"), result(language: "pl"),
                       result(language: "pl")]
        #expect(WhisperKitTranscriber.dominantLanguage(in: results) == "pl")
    }

    @Test("language codes are compared lower-cased")
    func dominantLowercases() {
        #expect(WhisperKitTranscriber.dominantLanguage(in: [result(language: "PL")]) == "pl")
    }

    /// The pinned tie rule. `Dictionary.max(by:)` over the counts would answer
    /// nondeterministically — dictionary iteration order is not stable — so
    /// identical audio could report a different language between runs. Ties
    /// go to the earliest window, which is also the one Whisper's own
    /// detection ran on.
    @Test("a tie goes to the earliest window, deterministically")
    func dominantTie() {
        #expect(WhisperKitTranscriber.dominantLanguage(
            in: [result(language: "pl"), result(language: "en")]) == "pl")
        #expect(WhisperKitTranscriber.dominantLanguage(
            in: [result(language: "en"), result(language: "pl")]) == "en")
        // And it stays the same answer however many times it is asked.
        let results = [result(language: "de"), result(language: "fr"),
                       result(language: "de"), result(language: "fr")]
        let answers = Set((0..<50).map { _ in
            WhisperKitTranscriber.dominantLanguage(in: results)
        })
        #expect(answers == ["de"])
    }

    // MARK: - confidence

    /// The floor the comparison leans on: a pass with nothing in it must lose
    /// every comparison rather than win one on a default of zero.
    @Test("no segments scores negative infinity")
    func confidenceEmpty() {
        #expect(WhisperKitTranscriber.confidence([]) == -.infinity)
        #expect(WhisperKitTranscriber.confidence([result(language: "en")]) == -.infinity)
        // …and that is genuinely the losing end of `chooseLanguage`.
        #expect(LanguagePolicy.chooseLanguage(
            detected: "pl", detectedScore: -0.5,
            alternative: "en", alternativeScore: -.infinity,
            lastUsed: "en", monitored: ["en", "pl"]) == "pl")
    }

    @Test("one segment scores its own log-probability")
    func confidenceSingle() {
        let results = [result(language: "en",
                              segments: [segment(start: 0, end: 4, avgLogprob: -0.25)])]
        #expect(abs(WhisperKitTranscriber.confidence(results) - -0.25) < 0.0001)
    }

    /// Duration-weighted, so a half-second aside cannot outvote ten seconds of
    /// speech. Unweighted, the mean below would be -0.55; weighted it stays
    /// near the long segment's -0.1.
    @Test("segments are weighted by duration, not counted equally")
    func confidenceWeighted() {
        let results = [result(language: "en", segments: [
            segment(start: 0, end: 10, avgLogprob: -0.1),
            segment(start: 10, end: 10.5, avgLogprob: -1.0),
        ])]
        let score = WhisperKitTranscriber.confidence(results)
        #expect(score > -0.2)
        #expect(score < -0.1)
    }

    /// A zero-length segment must not divide by zero or vanish; the floor of
    /// 0.1 on the weight is what keeps it a finite number.
    @Test("a zero-length segment still scores finitely")
    func confidenceZeroLength() {
        let results = [result(language: "en",
                              segments: [segment(start: 3, end: 3, avgLogprob: -0.5)])]
        let score = WhisperKitTranscriber.confidence(results)
        #expect(score.isFinite)
        #expect(abs(score - -0.5) < 0.0001)
    }

    @Test("segments are pooled across every result in the pass")
    func confidenceAcrossResults() {
        let results = [
            result(language: "en", segments: [segment(start: 0, end: 1, avgLogprob: -0.2)]),
            result(language: "en", segments: [segment(start: 1, end: 2, avgLogprob: -0.4)]),
        ]
        #expect(abs(WhisperKitTranscriber.confidence(results) - -0.3) < 0.0001)
    }
}
