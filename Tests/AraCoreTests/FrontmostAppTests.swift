import Foundation
import Testing
@testable import AraCore

@Suite("FrontmostApp")
struct FrontmostAppTests {
    /// The accessor is `@MainActor`-isolated by declaration, and that isolation
    /// is the whole safety story: it is what stops the read being reached from
    /// `DictationSession`'s executor, where `MainActor.assumeIsolated` around it
    /// would kill the process rather than hop. The compiler enforces the
    /// isolation, so what is left to check is that the read itself is survivable
    /// in a process with no frontmost application — the daemon performs it
    /// before any window of its own exists, and `nil` must come back rather than
    /// a trap.
    @Test("reading the frontmost bundle id on the main actor does not trap")
    @MainActor
    func readIsSafeWithNoFrontmostApplication() {
        _ = FrontmostApp.bundleID
    }
}
