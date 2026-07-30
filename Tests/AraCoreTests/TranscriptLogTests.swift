import Testing
@testable import AraCore

/// The daemon's stderr is a log file the moment `--launch-at-login` is used,
/// and a log file must not contain the text of everything the user ever
/// dictated. So the default `→`/`↦` lines carry timing and a character count
/// only; the full text appears only under an explicit `--echo-transcripts`.
@Suite("TranscriptLog")
struct TranscriptLogTests {
    // MARK: - the default: no transcript text

    @Test("the raw line is timing and character count only")
    func rawLineDefault() {
        let line = TranscriptLog.raw(
            seconds: 0.42, text: "Hello, is this thing on? Great, it is.",
            echoTranscript: false)
        #expect(line == "→ 0.42s · 38 chars")
    }

    @Test("the cleaned line is timing and character count only")
    func cleanedLineDefault() {
        let line = TranscriptLog.cleaned(
            seconds: 1.20, text: "Ship it.", echoTranscript: false)
        #expect(line == "↦ 1.20s · 8 chars")
    }

    /// The property the whole change exists for: whatever the transcript says,
    /// none of it reaches the default log line.
    @Test("the default lines never contain the transcript text")
    func defaultLinesLeakNothing() {
        let secret = "my card number is four two four two"
        #expect(!TranscriptLog.raw(seconds: 0.5, text: secret, echoTranscript: false)
            .contains("four"))
        #expect(!TranscriptLog.cleaned(seconds: 0.5, text: secret, echoTranscript: false)
            .contains("four"))
    }

    /// Characters, not bytes: the count a user can sanity-check against what
    /// landed at their cursor.
    @Test("the count is characters, not UTF-8 bytes")
    func countsCharacters() {
        #expect(TranscriptLog.raw(seconds: 0.10, text: "żółć 🦜", echoTranscript: false)
            == "→ 0.10s · 6 chars")
    }

    // MARK: - the opt-in

    @Test("--echo-transcripts restores the full text on the raw line")
    func rawLineEchoed() {
        let line = TranscriptLog.raw(
            seconds: 0.42, text: "Hello there.", echoTranscript: true)
        #expect(line == "→ 0.42s · Hello there.")
    }

    @Test("--echo-transcripts restores the full text on the cleaned line")
    func cleanedLineEchoed() {
        let line = TranscriptLog.cleaned(
            seconds: 2.05, text: "Ship it.", echoTranscript: true)
        #expect(line == "↦ 2.05s · Ship it.")
    }
}
