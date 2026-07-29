import Foundation
import Testing
@testable import AraCore

// `Formatter` is qualified throughout: Foundation exports a `Formatter` class,
// so an unqualified reference is ambiguous once this file imports both.
private struct StubFormatter: AraCore.Formatter {
    let behaviour: @Sendable (String, Mode) async throws -> String
    func format(_ text: String, mode: Mode) async throws -> String {
        try await behaviour(text, mode)
    }
}

/// Records the mode a formatter was invoked with.
private actor ModeRecorder {
    private(set) var seen: String?
    func record(_ id: String) { seen = id }
}

/// Records what a `@Sendable` callback was handed, from any executor.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    var current: T? { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("DictationSession")
struct DictationSessionTests {
    let resolver = ModeResolver(registry: ModeRegistry(userModes: []),
                                defaultID: "default")

    private func session(_ formatter: any AraCore.Formatter,
                         frontmost: @escaping @Sendable () -> String? = { nil },
                         onModeResolved: (@Sendable (Mode) -> Void)? = nil)
        -> DictationSession
    {
        DictationSession(formatter: formatter, resolver: resolver,
                         frontmostBundleID: frontmost,
                         onModeResolved: onModeResolved)
    }

    // MARK: - The transcript survives

    @Test("returns formatted text on success")
    func happyPath() async {
        let out = await session(RuleBasedFormatter())
            .process("um hello there friend", override: nil, manual: nil)
        #expect(out == "hello there friend")
    }

    @Test("returns the raw transcript when the formatter explodes")
    func neverLosesTranscript() async {
        let session = session(StubFormatter { _, _ in
            throw FormatterError.transportFailure("boom")
        })
        let raw = "this must survive a formatter failure"
        #expect(await session.process(raw, override: nil, manual: nil) == raw)
    }

    /// `Formatter` forbids an empty result for non-empty input, and nothing
    /// enforces that. Without this guard a broken formatter would erase an
    /// utterance through the same door cancellation leaves by — silently, since
    /// injecting `""` types nothing and raises nothing.
    @Test("an empty result for a non-empty transcript falls back to raw")
    func emptyResultFallsBack() async {
        let session = session(StubFormatter { _, _ in "" })
        let raw = "this must not be erased by a broken formatter"
        #expect(await session.process(raw, override: nil, manual: nil) == raw)
    }

    @Test("empty input stays empty")
    func emptyInput() async {
        #expect(await session(RuleBasedFormatter())
            .process("", override: nil, manual: nil) == "")
    }

    // MARK: - Mode selection

    @Test("frontmost app selects the mode")
    func usesFrontmostApp() async {
        let recorder = ModeRecorder()
        let session = session(
            StubFormatter { text, mode in
                await recorder.record(mode.id)
                return text
            },
            frontmost: { "com.apple.mail" })
        _ = await session.process("hello there friend", override: nil, manual: nil)
        #expect(await recorder.seen == "email")
    }

    @Test("an explicit override outranks the frontmost app")
    func overrideBeatsFrontmostApp() async {
        let recorder = ModeRecorder()
        let session = session(
            StubFormatter { text, mode in
                await recorder.record(mode.id)
                return text
            },
            frontmost: { "com.apple.mail" })
        _ = await session.process("hello there friend", override: "chat", manual: nil)
        #expect(await recorder.seen == "chat")
    }

    /// The menu bar's mode label is driven by this callback, so it has to fire
    /// with the mode formatting actually used — not with the configured default.
    @Test("the resolved mode is reported to the caller")
    func reportsResolvedMode() async {
        let reported = Box<String>()
        let session = session(RuleBasedFormatter(),
                              frontmost: { "com.tinyspeck.slackmacgap" },
                              onModeResolved: { reported.set($0.id) })
        _ = await session.process("hello there friend", override: nil, manual: nil)
        #expect(reported.current == "chat")
    }

    // MARK: - Cancellation

    /// A withdrawn request must not produce text. `process` cannot throw — that
    /// is the "never lose the transcript" guarantee made structural — so it
    /// returns the one string that is safe to hand an injector.
    @Test("a cancelled request yields nothing to inject")
    func cancellationYieldsNothing() async throws {
        let session = session(StubFormatter { _, _ in
            try await Task.sleep(for: .seconds(30))
            return "never"
        })
        let running = Task {
            await session.process("hello there friend", override: nil, manual: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        running.cancel()
        #expect(await running.value == "")
    }

    /// The hole a catch block cannot see. `RuleBasedFormatter` is pure string
    /// work with no suspension point: cancelled mid-call it returns a perfectly
    /// good string and raises nothing. Only the check *after* the work catches
    /// it, and this stub reproduces that by blocking its thread with `usleep`
    /// and returning normally.
    @Test("a cancelled request yields nothing even when the formatter cannot observe it")
    func cancellationWithUnobservingFormatter() async throws {
        let session = session(StubFormatter { _, _ in
            usleep(200_000)
            return "CLEANED"
        })
        let running = Task {
            await session.process("hello there friend", override: nil, manual: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        running.cancel()
        #expect(await running.value == "")
    }

    /// The mirror image: a `CancellationError` is not evidence that our caller
    /// withdrew anything. A formatter can leak one from an internal task group
    /// while the caller is alive and still waiting for its text. Deciding on the
    /// error's type rather than on `Task.isCancelled` would throw that
    /// transcript away.
    @Test("a stray CancellationError from a live caller still returns the transcript")
    func strayCancellationKeepsTranscript() async {
        let session = session(StubFormatter { _, _ in throw CancellationError() })
        let raw = "hello there friend"
        #expect(await session.process(raw, override: nil, manual: nil) == raw)
        #expect(!Task.isCancelled)
    }

    /// An already-withdrawn request must not spend an inference on its way to
    /// producing nothing.
    @Test("an already-cancelled request never reaches the formatter")
    func alreadyCancelledSkipsFormatter() async {
        let session = session(StubFormatter { _, _ in
            Issue.record("the formatter ran for an already-cancelled request")
            return "x"
        })
        let running = Task { () async -> String in
            while !Task.isCancelled { await Task.yield() }
            return await session.process("hello there friend",
                                         override: nil, manual: nil)
        }
        running.cancel()
        #expect(await running.value == "")
    }
}
