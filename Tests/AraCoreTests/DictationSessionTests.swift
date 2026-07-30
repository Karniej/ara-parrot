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

/// A one-shot latch, so an interleaving can be stated rather than raced for.
/// Polls instead of sleeping a fixed interval: a wait long enough to be reliable
/// would be slow, and one short enough to be quick would be flaky.
private actor Gate {
    private var isOpen = false
    func open() { isOpen = true }

    func wait(upTo limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !isOpen, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
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
                         dictionary: @escaping @Sendable () -> LocalDictionary
                             = { LocalDictionary() },
                         snippets: @escaping @Sendable () -> Snippets
                             = { Snippets() },
                         onModeResolved: (@Sendable (Mode) -> Void)? = nil)
        -> DictationSession
    {
        DictationSession(formatter: formatter, resolver: resolver,
                         dictionary: dictionary, snippets: snippets,
                         onModeResolved: onModeResolved)
    }

    // MARK: - The transcript survives

    @Test("returns formatted text on success")
    func happyPath() async {
        let out = await session(RuleBasedFormatter())
            .process("um hello there friend", override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == "hello there friend")
    }

    @Test("returns the raw transcript when the formatter explodes")
    func neverLosesTranscript() async {
        let session = session(StubFormatter { _, _ in
            throw FormatterError.transportFailure("boom")
        })
        let raw = "this must survive a formatter failure"
        #expect(await session.process(raw, override: nil, manual: nil, frontmostBundleID: nil) == raw)
    }

    /// `Formatter` forbids an empty result for non-empty input, and nothing
    /// enforces that. Without this guard a broken formatter would erase an
    /// utterance through the same door cancellation leaves by — silently, since
    /// injecting `""` types nothing and raises nothing.
    @Test("an empty result for a non-empty transcript falls back to raw")
    func emptyResultFallsBack() async {
        let session = session(StubFormatter { _, _ in "" })
        let raw = "this must not be erased by a broken formatter"
        #expect(await session.process(raw, override: nil, manual: nil, frontmostBundleID: nil) == raw)
    }

    @Test("empty input stays empty")
    func emptyInput() async {
        #expect(await session(RuleBasedFormatter())
            .process("", override: nil, manual: nil, frontmostBundleID: nil) == "")
    }

    // MARK: - The dictionary runs first

    /// The point of the pipeline position: every formatting engine sees
    /// corrected text, so an LLM cannot paraphrase a term it never saw
    /// misheard. Proved on the formatter's *input*, not on the session's
    /// output — an implementation that corrected after formatting would
    /// produce the same final string here and be wrong everywhere else.
    @Test("the dictionary corrects the transcript before the formatter sees it")
    func dictionaryRunsBeforeTheFormatter() async {
        let received = Box<String>()
        let session = session(
            StubFormatter { text, _ in
                received.set(text)
                return text
            },
            dictionary: {
                LocalDictionary(entries: [
                    .init(canonical: "Ara", variants: ["arra"])
                ])
            })
        let out = await session.process("tell arra hello", override: nil,
                                        manual: nil, frontmostBundleID: nil)
        #expect(received.current == "tell Ara hello")
        #expect(out == "tell Ara hello")
    }

    /// Corrections are about what the user said, not how it is formatted, so
    /// the never-lose-the-transcript fallback returns the *corrected* text —
    /// a formatter failure must not also undo the dictionary.
    @Test("a formatter failure falls back to the corrected transcript")
    func formatterFailureKeepsCorrections() async {
        let session = session(
            StubFormatter { _, _ in throw FormatterError.transportFailure("boom") },
            dictionary: {
                LocalDictionary(entries: [
                    .init(canonical: "Ara", variants: ["arra"])
                ])
            })
        let out = await session.process("tell arra hello", override: nil,
                                        manual: nil, frontmostBundleID: nil)
        #expect(out == "tell Ara hello")
    }

    /// Hot reload lives in the source closure: the session must consult it
    /// per utterance, never capture one dictionary at init.
    @Test("the dictionary source is consulted fresh for every utterance")
    func dictionarySourceIsConsultedPerUtterance() async {
        let generation = Box<Int>()
        generation.set(0)
        let session = session(
            StubFormatter { text, _ in text },
            dictionary: {
                let now = (generation.current ?? 0) + 1
                generation.set(now)
                return LocalDictionary(entries: [
                    .init(canonical: "generation \(now)", variants: ["marker"])
                ])
            })
        let first = await session.process("marker", override: nil, manual: nil,
                                          frontmostBundleID: nil)
        let second = await session.process("marker", override: nil, manual: nil,
                                           frontmostBundleID: nil)
        #expect(first == "generation 1")
        #expect(second == "generation 2")
    }

    // MARK: - Snippets short-circuit

    /// The whole point of the feature: a dictated trigger yields the authored
    /// expansion verbatim — newlines and all — and the formatter is never
    /// consulted, so no LLM, mode prompt, or output guard can mangle it.
    @Test("a snippet hit injects the expansion verbatim and skips the formatter")
    func snippetHitSkipsFormatter() async {
        let expansion = "Best regards,\nPawel Karniej\nSilpho\n"
        let session = session(
            StubFormatter { _, _ in
                Issue.record("the formatter ran for a snippet hit")
                return "MANGLED"
            },
            snippets: {
                Snippets(entries: [
                    .init(trigger: "sign off formal", expansion: expansion)
                ])
            })
        let out = await session.process("Sign off formal.", override: nil,
                                        manual: nil, frontmostBundleID: nil)
        #expect(out == expansion)
    }

    /// The near-miss: an utterance *containing* the trigger is a real
    /// sentence, and it must take the normal path — formatter consulted,
    /// expansion nowhere in sight.
    @Test("a sentence containing the trigger is formatted normally")
    func snippetNearMissUsesFormatter() async {
        let received = Box<String>()
        let session = session(
            StubFormatter { text, _ in
                received.set(text)
                return "formatted: \(text)"
            },
            snippets: {
                Snippets(entries: [
                    .init(trigger: "sign off formal", expansion: "Best,\nPawel")
                ])
            })
        let out = await session.process("please sign off formal here",
                                        override: nil, manual: nil,
                                        frontmostBundleID: nil)
        #expect(received.current == "please sign off formal here")
        #expect(out == "formatted: please sign off formal here")
    }

    /// The pipeline position, proved from the dictionary side: corrections
    /// run first, so a trigger word the ASR mishears can be fixed by the
    /// dictionary and the snippet still fires.
    @Test("the dictionary corrects a misheard trigger before matching")
    func snippetMatchesAfterDictionaryCorrection() async {
        let session = session(
            StubFormatter { _, _ in
                Issue.record("the formatter ran for a corrected snippet hit")
                return "MANGLED"
            },
            dictionary: {
                LocalDictionary(entries: [
                    .init(canonical: "sign", variants: ["sine"])
                ])
            },
            snippets: {
                Snippets(entries: [
                    .init(trigger: "sign off formal", expansion: "Best,\nPawel")
                ])
            })
        let out = await session.process("sine off formal", override: nil,
                                        manual: nil, frontmostBundleID: nil)
        #expect(out == "Best,\nPawel")
    }

    /// A snippet hit short-circuits *before* mode resolution: no mode is
    /// resolved and none reported, because the utterance was never formatted
    /// in any mode — the expansion is authored text, not speech.
    @Test("a snippet hit resolves no mode")
    func snippetHitResolvesNoMode() async {
        let reported = Box<String>()
        let session = session(
            StubFormatter { text, _ in text },
            snippets: {
                Snippets(entries: [
                    .init(trigger: "sign off", expansion: "Best")
                ])
            },
            onModeResolved: { reported.set($0.id) })
        _ = await session.process("sign off", override: nil, manual: nil,
                                  frontmostBundleID: "com.apple.mail")
        #expect(reported.current == nil)
    }

    /// Hot reload lives in the source closure, exactly as for the dictionary:
    /// the session must consult it per utterance, never capture one value.
    @Test("the snippets source is consulted fresh for every utterance")
    func snippetsSourceIsConsultedPerUtterance() async {
        let generation = Box<Int>()
        generation.set(0)
        let session = session(
            StubFormatter { text, _ in text },
            snippets: {
                let now = (generation.current ?? 0) + 1
                generation.set(now)
                return Snippets(entries: [
                    .init(trigger: "marker", expansion: "generation \(now)")
                ])
            })
        let first = await session.process("marker", override: nil, manual: nil,
                                          frontmostBundleID: nil)
        let second = await session.process("marker", override: nil, manual: nil,
                                           frontmostBundleID: nil)
        #expect(first == "generation 1")
        #expect(second == "generation 2")
    }

    // MARK: - Mode selection

    @Test("frontmost app selects the mode")
    func usesFrontmostApp() async {
        let recorder = ModeRecorder()
        let session = session(
            StubFormatter { text, mode in
                await recorder.record(mode.id)
                return text
            })
        _ = await session.process("hello there friend", override: nil, manual: nil,
                                  frontmostBundleID: "com.apple.mail")
        #expect(await recorder.seen == "email")
    }

    @Test("an explicit override outranks the frontmost app")
    func overrideBeatsFrontmostApp() async {
        let recorder = ModeRecorder()
        let session = session(
            StubFormatter { text, mode in
                await recorder.record(mode.id)
                return text
            })
        _ = await session.process("hello there friend", override: "chat", manual: nil,
                                  frontmostBundleID: "com.apple.mail")
        #expect(await recorder.seen == "chat")
    }

    /// The menu bar's mode label is driven by this callback, so it has to fire
    /// with the mode formatting actually used — not with the configured default.
    @Test("the resolved mode is reported to the caller")
    func reportsResolvedMode() async {
        let reported = Box<String>()
        let session = session(RuleBasedFormatter(),
                              onModeResolved: { reported.set($0.id) })
        _ = await session.process("hello there friend", override: nil, manual: nil,
                                  frontmostBundleID: "com.tinyspeck.slackmacgap")
        #expect(reported.current == "chat")
    }

    /// The failure this parameter exists to make impossible.
    ///
    /// `process` runs seconds after the hotkey was released, once transcription
    /// has finished, so a user who starts a second utterance before the first
    /// comes back has two formatting calls in flight at once. When the frontmost
    /// application was a single slot the session read at format time, the second
    /// utterance's sample overwrote the first's and the first was formatted in
    /// the wrong mode — speech dictated into Mail arriving as a code-mode
    /// rewrite. No text was lost, which is why nothing else in the suite caught
    /// it.
    ///
    /// The overlap here is not a race left to timing: utterance one is held
    /// inside `format` until utterance two has run to completion, so the
    /// interleaving is the same on every run and on every machine.
    @Test("interleaved utterances each keep their own frontmost sample")
    func interleavedUtterancesKeepTheirOwnSample() async {
        let secondFinished = Gate()
        let session = session(StubFormatter { text, mode in
            if text.hasPrefix("first") {
                await secondFinished.wait(upTo: .seconds(5))
            } else {
                await secondFinished.open()
            }
            return "mode \(mode.id) for \(text)"
        })

        async let first = session.process(
            "first utterance spoken here", override: nil, manual: nil,
            frontmostBundleID: "com.apple.mail")
        async let second = session.process(
            "second utterance spoken here", override: nil, manual: nil,
            frontmostBundleID: "com.apple.dt.Xcode")

        #expect(await first == "mode email for first utterance spoken here")
        #expect(await second == "mode code for second utterance spoken here")
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
            await session.process("hello there friend", override: nil, manual: nil, frontmostBundleID: nil)
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
            await session.process("hello there friend", override: nil, manual: nil, frontmostBundleID: nil)
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
        #expect(await session.process(raw, override: nil, manual: nil, frontmostBundleID: nil) == raw)
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
                                         override: nil, manual: nil,
                                         frontmostBundleID: nil)
        }
        running.cancel()
        #expect(await running.value == "")
    }
}
