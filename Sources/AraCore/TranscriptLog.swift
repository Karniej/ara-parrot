import Foundation

/// Formats the per-utterance `→` (raw) and `↦` (cleaned) stderr lines.
///
/// stderr stops being ephemeral the moment the daemon runs under launchd: it
/// becomes a file, appended to for as long as the agent lives. A log line that
/// quotes the transcript therefore accumulates everything the user ever
/// dictated — passwords read aloud, medical notes, all of it — in whatever
/// file the plist points at. So the default line carries only what debugging
/// timing needs: how long the stage took and how much text it produced.
///
/// `--echo-transcripts` restores the full text for interactive sessions where
/// the user has chosen to watch their own words scroll by. The flag is a
/// per-run choice and is deliberately never written into the LaunchAgent's
/// `ProgramArguments` — see `Install.agentPlist`.
public enum TranscriptLog {
    /// The `→` line: raw transcript out of the transcriber.
    public static func raw(seconds: Double, text: String,
                           echoTranscript: Bool) -> String {
        line(arrow: "→", seconds: seconds, text: text, echo: echoTranscript)
    }

    /// The `↦` line: formatted text, when formatting changed something.
    public static func cleaned(seconds: Double, text: String,
                               echoTranscript: Bool) -> String {
        line(arrow: "↦", seconds: seconds, text: text, echo: echoTranscript)
    }

    private static func line(arrow: String, seconds: Double, text: String,
                             echo: Bool) -> String {
        // Characters, not UTF-8 bytes: the count a user can compare against
        // what landed at their cursor.
        let payload = echo ? text : "\(text.count) chars"
        return String(format: "%@ %.2fs · %@", arrow, seconds, payload)
    }
}
