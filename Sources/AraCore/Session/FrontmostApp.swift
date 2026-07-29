import AppKit
import Foundation
import os

/// A thread-safe snapshot of which application the user was dictating into.
///
/// `DictationSession` needs the frontmost bundle identifier from inside its own
/// actor, and both obvious ways of reading it there are wrong:
///
/// - `MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication }` is a
///   *precondition*, not a hop. Called from the session's executor it does not
///   move the work to the main thread — it trips
///   "Incorrect actor executor assumption" and kills the daemon on the first
///   dictation. `NSWorkspace` carries no `@MainActor` annotation in the SDK, so
///   the compiler will not catch this for you.
/// - `DispatchQueue.main.sync` would trade the trap for a cooperative-pool
///   thread parked on the main run loop. That is the same class of stall the
///   formatting layer spends an entire deadline mechanism avoiding, with a
///   deadlock available whenever the main thread is itself waiting on this work.
///
/// So the AppKit read happens where it is trivially legal — on the main actor,
/// at the moment the hotkey is released — and lands in a lock-protected box the
/// session reads without suspending, blocking, or asserting anything about its
/// executor. `os_unfair_lock` around a single `String?` is uncontended in
/// practice: one write per utterance from the main thread, one read per
/// utterance from the session.
///
/// Capturing at release rather than at injection time is also the more faithful
/// answer to "which app is this for". It names the app the user was speaking
/// into, before a second or two of transcription gave them time to switch away.
public final class FrontmostApp: Sendable {
    private let cached = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let read: @MainActor @Sendable () -> String?

    public convenience init() {
        self.init(read: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
    }

    /// Injectable seam so the box can be exercised without a running app or a
    /// window server. The default is the only reader production uses.
    init(read: @escaping @MainActor @Sendable () -> String?) {
        self.read = read
    }

    /// Samples the frontmost application. Main-actor-isolated because that is
    /// the only context in which the AppKit read is safe; call it at the moment
    /// the user stops speaking.
    @MainActor
    public func capture() {
        let id = read()
        cached.withLock { $0 = id }
    }

    /// The most recent sample, or `nil` if nothing has been captured yet. Safe
    /// from any thread or executor.
    public var bundleID: String? { cached.withLock { $0 } }

    /// `bundleID` in the shape `DictationSession` takes. Shares this instance's
    /// storage — `OSAllocatedUnfairLock` is a handle to one allocation, so a
    /// copy captured by the closure sees every later `capture()`.
    public var reader: @Sendable () -> String? {
        let cached = self.cached
        return { cached.withLock { $0 } }
    }
}
