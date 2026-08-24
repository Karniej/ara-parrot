import Foundation

/// Which utterance the screen currently belongs to.
///
/// Dictation is not serial. A user releases the hotkey, the transcription and
/// the local rewrite take a few seconds, and nothing stops them pressing the
/// key again while that is still running — Ara records the second utterance
/// correctly and delivers both. What went wrong was only the *screen*: the
/// first utterance's completion ended with an unconditional `overlay.hide()`
/// and `menuBar.setRecording(false)`, so the moment the first transcript was
/// injected, the recording pill for the second one vanished from under it.
/// The daemon was still listening and the user had no way to know.
///
/// So a completion is not allowed to clear anything on its own authority. It
/// carries the token its press was given, and only tears the screen down if
/// that token is still the newest one. A superseded utterance delivers its
/// text — that part is never conditional — and then leaves the display to the
/// utterance that owns it.
///
/// The same token discipline as `RecordingOverlay.showToken` and
/// `RunningModel.generation`, for the same reason: work already in flight
/// cannot be recalled, only declined when it lands.
///
/// Main-actor because both ends are already there — the hotkey handler that
/// begins an utterance, and the completion that hops back to touch AppKit.
@MainActor
public final class UtteranceGeneration {
    /// `nil` until the first press, rather than zero. A counter that starts at
    /// a real number answers "yes, that is the current utterance" to a token
    /// nobody issued — a zero-initialised slot, a default argument — and the
    /// answer this type exists to give is the cautious one.
    private var current: Int?

    public init() {}

    /// The token of the utterance currently on screen, or `nil` if no press has
    /// begun one. Read at hotkey release, so the completion that follows knows
    /// which utterance it is finishing.
    public var token: Int? { current }

    /// Claims the screen for a new utterance and returns its token. Every call
    /// returns a value no earlier call returned, so a token can go stale but
    /// can never become current again.
    public func begin() -> Int {
        let next = (current ?? 0) + 1
        current = next
        return next
    }

    /// Whether `token`'s utterance is still the one on screen. False once a
    /// newer press has begun, and false before any press at all.
    public func isCurrent(_ token: Int) -> Bool {
        token == current
    }
}
