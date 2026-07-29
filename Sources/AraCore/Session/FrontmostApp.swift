import AppKit
import Foundation

/// Reads which application is frontmost right now.
///
/// A single main-actor-isolated read, because both obvious ways of doing this
/// from the dictation path are wrong:
///
/// - `MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication }` is a
///   *precondition*, not a hop. Called from anywhere but the main actor it does
///   not move the work to the main thread — it trips "Incorrect actor executor
///   assumption" and kills the daemon. `NSWorkspace` carries no `@MainActor`
///   annotation in the SDK, so the compiler will not catch this for you;
///   reinstating that version has been observed to kill a test process with
///   SIGTRAP.
/// - `DispatchQueue.main.sync` would trade the trap for a cooperative-pool
///   thread parked on the main run loop. That is the same class of stall the
///   formatting layer spends an entire deadline mechanism avoiding, with a
///   deadlock available whenever the main thread is itself waiting on that work.
///
/// So the AppKit read happens where it is trivially legal — on the main actor,
/// at the moment the hotkey is released — and the resulting `String?` is carried
/// to `DictationSession.process` **by value, for that one utterance**.
///
/// That last part is the design, not an implementation detail. An earlier
/// version cached the answer in a shared slot the session read at format time,
/// and it mis-attributed overlapping utterances: formatting happens seconds
/// after release, once transcription finishes, so a user who starts a second
/// utterance before the first comes back overwrites the slot and the first
/// utterance is formatted in the second one's mode — speech dictated into Mail
/// arriving as a code-mode rewrite. A value sampled at release and carried
/// alongside its own transcript cannot be overwritten by a later utterance,
/// which makes the property structural rather than a matter of timing.
public enum FrontmostApp {
    /// The frontmost application's bundle identifier, sampled now.
    ///
    /// Main-actor-isolated because that is the only context in which the read is
    /// safe. Sample it when the user stops speaking and pass the value on; do
    /// not hold the accessor itself for later.
    @MainActor
    public static var bundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
