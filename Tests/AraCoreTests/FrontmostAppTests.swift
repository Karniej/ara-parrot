import Foundation
import Testing
@testable import AraCore

private struct ModeReportingFormatter: AraCore.Formatter {
    func format(_ text: String, mode: Mode) async throws -> String { mode.id }
}

@Suite("FrontmostApp")
struct FrontmostAppTests {
    @Test("reads nothing before the first capture")
    func emptyBeforeCapture() {
        let tracker = FrontmostApp(read: { "com.apple.mail" })
        #expect(tracker.bundleID == nil)
        #expect(tracker.reader() == nil)
    }

    @Test("capture samples the frontmost application")
    @MainActor
    func captureSamples() {
        let tracker = FrontmostApp(read: { "com.apple.mail" })
        tracker.capture()
        #expect(tracker.bundleID == "com.apple.mail")
    }

    /// `reader` must share storage with the tracker rather than snapshot it:
    /// the daemon hands the closure to `DictationSession` once, at startup, and
    /// captures a new value before every utterance.
    @Test("reader sees captures made after it was created")
    @MainActor
    func readerSharesStorage() {
        let current = Box()
        let tracker = FrontmostApp(read: { current.value })
        let read = tracker.reader

        current.value = "com.apple.mail"
        tracker.capture()
        #expect(read() == "com.apple.mail")

        current.value = "com.tinyspeck.slackmacgap"
        tracker.capture()
        #expect(read() == "com.tinyspeck.slackmacgap")
    }

    /// The reason this type exists. `DictationSession` calls the closure from
    /// its own actor's executor, where `MainActor.assumeIsolated` around an
    /// AppKit read is not a hop but a trap — the daemon would die on the first
    /// dictation. Driving it through a real session is the only way to test that
    /// from the context that actually breaks.
    @Test("the reader works from inside the session's actor")
    @MainActor
    func readableFromTheSessionActor() async {
        let tracker = FrontmostApp(read: { "com.apple.mail" })
        tracker.capture()
        let session = DictationSession(
            formatter: ModeReportingFormatter(),
            resolver: ModeResolver(registry: ModeRegistry(userModes: []),
                                   defaultID: "default"),
            frontmostBundleID: tracker.reader)
        #expect(await session.process("hello there friend",
                                      override: nil, manual: nil) == "email")
    }
}

/// Main-actor-confined mutable cell for the injected reader.
@MainActor
private final class Box {
    var value: String?
}
