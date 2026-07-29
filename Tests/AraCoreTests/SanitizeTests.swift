import Testing
@testable import AraCore

@Suite("sanitize")
struct SanitizeTests {
    @Test("strips bracket tokens")
    func stripsBrackets() {
        #expect(WhisperKitTranscriber.sanitize("[BLANK_AUDIO]") == "")
        #expect(WhisperKitTranscriber.sanitize("hello [MUSIC] world") == "hello world")
    }

    @Test("strips parenthetical and angle tokens")
    func stripsOtherTokens() {
        #expect(WhisperKitTranscriber.sanitize("(silence) done") == "done")
        #expect(WhisperKitTranscriber.sanitize("<|nospeech|>hi") == "hi")
        #expect(WhisperKitTranscriber.sanitize("*cough* ok") == "ok")
    }

    @Test("collapses whitespace and trims")
    func collapsesWhitespace() {
        #expect(WhisperKitTranscriber.sanitize("  a    b  ") == "a b")
    }

    @Test("leaves ordinary speech untouched")
    func leavesSpeechAlone() {
        #expect(WhisperKitTranscriber.sanitize("one, two, three.") == "one, two, three.")
    }

    @Test("replaces tokens with a separator, not nothing")
    func replacesWithSeparator() {
        #expect(WhisperKitTranscriber.sanitize("a[X]b") == "a b")
    }

    @Test("known limitation: parenthesised speech is dropped")
    func dropsParentheticalSpeech() {
        // Upstream behaviour, pinned deliberately: the (silence)/(music) filter
        // cannot distinguish non-speech markers from real parenthesised words.
        #expect(WhisperKitTranscriber.sanitize("call me (later) today") == "call me today")
    }
}
