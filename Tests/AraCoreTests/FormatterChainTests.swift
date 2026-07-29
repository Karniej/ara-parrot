import Foundation
import Testing
@testable import AraCore

// `Formatter` is qualified throughout: Foundation exports a `Formatter` class,
// so an unqualified reference is ambiguous once this file imports both.
private struct StubFormatter: AraCore.Formatter {
    let behaviour: @Sendable (String) async throws -> String
    func format(_ text: String, mode: Mode) async throws -> String {
        try await behaviour(text)
    }
}

/// Records whether the work the chain abandoned actually observed cancellation.
private actor CancellationProbe {
    private(set) var observed = false
    func record() { observed = true }

    /// Polls rather than sleeping a fixed interval: cancellation is delivered
    /// asynchronously, so the only alternatives are a wait long enough to be
    /// slow or short enough to be flaky.
    func waitForObservation(upTo limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if observed { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return observed
    }
}

@Suite("FormatterChain")
struct FormatterChainTests {
    let mode = Mode(id: "default", name: "Default", prompt: "p",
                    appBundleIDs: [], usesLLM: true)
    fileprivate let rules = StubFormatter { _ in "RULES" }

    @Test("local engine uses local when it succeeds")
    func localSucceeds() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in "one two three four" },
            cloud: nil, rules: rules)
        #expect(try await chain.format("one two three four five", mode: mode)
                == "one two three four")
    }

    @Test("local failure falls through to rules")
    func localFallsBack() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    @Test("a hung formatter is abandoned at the deadline")
    func deadlineFires() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .milliseconds(80),
            local: StubFormatter { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            },
            cloud: nil, rules: rules)
        let started = Date()
        let result = try await chain.format("hello there friend", mode: mode)
        #expect(result == "RULES")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// The deadline must hold even when the engine ignores cancellation.
    /// A local model doing synchronous inference, or a C library blocked on a
    /// socket, never reaches a suspension point, so `Task.cancel` is a no-op on
    /// it. This stub reproduces that by blocking its thread outright. A
    /// structured task group cannot satisfy this test: the group awaits every
    /// child before it returns, so the caller would wait the full three seconds.
    @Test("a formatter that ignores cancellation is still abandoned")
    func deadlineFiresOnUncooperativeWork() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .milliseconds(80),
            local: StubFormatter { _ in
                usleep(3_000_000)
                return "never"
            },
            cloud: nil, rules: rules)
        let started = Date()
        let result = try await chain.format("hello there friend", mode: mode)
        #expect(result == "RULES")
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("implausible output is discarded")
    func guardsOutput() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in "Paris" },
            cloud: nil, rules: rules)
        #expect(try await chain.format("what is the capital of France", mode: mode)
                == "RULES")
    }

    @Test("cloud engine falls through cloud, then local, then rules")
    func cloudChain() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            local: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: StubFormatter { _ in throw FormatterError.refused },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    /// A default install performs no network I/O, so `.local` must never reach
    /// for a cloud formatter even when one is configured and available.
    @Test("local engine never reaches for cloud")
    func localNeverUsesCloud() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: StubFormatter { _ in
                Issue.record("cloud was called under the local engine")
                return "CLOUD"
            },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    @Test("cloud engine prefers cloud when it succeeds")
    func cloudPreferred() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            local: StubFormatter { _ in
                Issue.record("local was called after cloud succeeded")
                return "LOCAL"
            },
            cloud: StubFormatter { _ in "hello there friend." },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend.")
    }

    @Test("rules engine uses the rule-based formatter directly")
    func rulesEngine() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(1),
            local: StubFormatter { _ in
                Issue.record("LLM was called under the rules engine")
                return "x"
            },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    @Test("off engine returns the raw text untouched")
    func offEngine() async throws {
        let chain = FormatterChain(
            engine: .off, timeout: .seconds(1),
            local: StubFormatter { _ in "formatted" }, cloud: nil, rules: rules)
        #expect(try await chain.format("raw text here", mode: mode) == "raw text here")
    }

    @Test("verbatim mode never reaches the LLM")
    func verbatimSkipsLLM() async throws {
        let verbatim = Mode(id: "verbatim", name: "V", prompt: "",
                            appBundleIDs: [], usesLLM: false)
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in Issue.record("LLM was called"); return "x" },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: verbatim) == "RULES")
    }

    /// Cancellation is not an engine failure. A caller that withdraws the
    /// request must get `CancellationError`, not a string — a string would be
    /// typed at the user's cursor by the injection layer, which has no way to
    /// tell a real result from an absorbed cancellation.
    @Test("a cancelled caller gets CancellationError rather than text")
    func cancellationPropagates() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(30),
            local: StubFormatter { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            },
            cloud: StubFormatter { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            },
            rules: rules)
        let mode = mode
        let running = Task { try await chain.format("hello there friend", mode: mode) }
        try await Task.sleep(for: .milliseconds(50))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    /// The same guarantee on the branch that never consults an engine: a
    /// cancelled verbatim-mode call must not hand back text either.
    @Test("a cancelled caller gets CancellationError on the rules-only branch")
    func cancellationPropagatesFromRulesBranch() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(30),
            local: nil, cloud: nil,
            rules: StubFormatter { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            })
        let mode = mode
        let running = Task { try await chain.format("hello there friend", mode: mode) }
        try await Task.sleep(for: .milliseconds(50))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    /// Abandoning the loser must also *cancel* it. Without this, a well-behaved
    /// engine that could have stopped at the deadline keeps running to
    /// completion, burning a pool thread and, for cloud, real money.
    @Test("the losing formatter is cancelled once the deadline fires")
    func loserIsCancelled() async throws {
        let probe = CancellationProbe()
        let chain = FormatterChain(
            engine: .local, timeout: .milliseconds(50),
            local: StubFormatter { _ in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    await probe.record()
                    throw error
                }
                return "never"
            },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(await probe.waitForObservation(upTo: .seconds(2)))
    }

    /// The mirror image: when the work wins, the timer must be cancelled too,
    /// so a one-second deadline does not keep a task alive for a second after
    /// a formatter that returned in a millisecond.
    @Test("the timer is cancelled once the formatter wins")
    func timerIsCancelledOnSuccess() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(30),
            local: StubFormatter { _ in "one two three four" },
            cloud: nil, rules: rules)
        let started = ContinuousClock.now
        #expect(try await chain.format("one two three four five", mode: mode)
                == "one two three four")
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    /// The type system does not back the "rules cannot fail" claim: `rules` is
    /// an `any Formatter` and anything can be passed. The chain must survive a
    /// broken one rather than losing the transcript.
    @Test("a throwing rules formatter still yields the raw transcript")
    func brokenRulesStillReturnsText() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: nil,
            rules: StubFormatter { _ in throw FormatterError.transportFailure("broken") })
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend")
    }

    /// The chain's contract says there is "no way for one to hang". That was
    /// true only of the *concrete* `RuleBasedFormatter`; the parameter is typed
    /// `any Formatter`, and the terminal step used to await it with no deadline
    /// at all. Blocking rather than sleeping, so the stub cannot be rescued by
    /// cancellation — the deadline has to be what ends the wait.
    ///
    /// Mutation: drop the `withDeadline` wrapper from `terminalFallback` and
    /// this returns `"RULES"` after ~400ms instead of the raw transcript after
    /// ~60ms, failing both expectations.
    @Test("a hung rule-based floor cannot hang the dictation")
    func rulesFloorIsDeadlined() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .milliseconds(60),
            local: nil, cloud: nil,
            rules: StubFormatter { _ in
                usleep(400_000)
                return "RULES"
            })
        let started = ContinuousClock.now
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend")
        #expect(ContinuousClock.now - started < .milliseconds(300))
    }

    /// The same protection on the verbatim fast path, which reaches the floor by
    /// a different branch (`!mode.usesLLM`) and is the path most utterances take
    /// when the user has picked verbatim.
    @Test("the verbatim fast path is deadlined too")
    func verbatimFloorIsDeadlined() async throws {
        let verbatim = Mode(id: "verbatim", name: "V", prompt: "",
                            appBundleIDs: [], usesLLM: false)
        let chain = FormatterChain(
            engine: .local, timeout: .milliseconds(60),
            local: nil, cloud: nil,
            rules: StubFormatter { _ in
                usleep(400_000)
                return "RULES"
            })
        let started = ContinuousClock.now
        #expect(try await chain.format("hello there friend", mode: verbatim)
                == "hello there friend")
        #expect(ContinuousClock.now - started < .milliseconds(300))
    }

    @Test("a throwing rules formatter is survivable on the rules-only branch too")
    func brokenRulesOnRulesBranch() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(1),
            local: nil, cloud: nil,
            rules: StubFormatter { _ in throw FormatterError.unavailable })
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend")
    }

    /// A `CancellationError` is not proof that *our* caller cancelled. A
    /// formatter can leak one from an internal task group whose child was
    /// cancelled, with the caller very much alive and still wanting its text.
    /// Deciding on the error's type rather than on `Task.isCancelled` would
    /// throw that transcript away.
    @Test("a stray CancellationError from an engine does not lose the transcript")
    func strayCancellationFromEngineFallsThrough() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in throw CancellationError() },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(!Task.isCancelled)
    }

    @Test("a stray CancellationError from rules does not lose the transcript")
    func strayCancellationFromRulesFallsThrough() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(1),
            local: nil, cloud: nil,
            rules: StubFormatter { _ in throw CancellationError() })
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend")
        #expect(!Task.isCancelled)
    }

    /// The converse hole, and the one the round-1 tests missed because their
    /// stub `rules` happened to suspend. The real `RuleBasedFormatter` is pure
    /// string work with no suspension point, so it cannot observe cancellation
    /// at all: a call cancelled while it ran would *succeed*, return a string,
    /// and raise no error anywhere for the chain to catch.
    ///
    /// The stub blocks with `usleep` rather than `Task.sleep` precisely so it
    /// cannot notice the cancellation, and returns normally. Only a check after
    /// the work completes catches this — a check at entry cannot, because the
    /// caller was still alive at entry.
    @Test("a cancelled caller gets no text from a formatter that ignores cancellation")
    func cancelledCallerGetsNoTextFromIgnoringFormatter() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(5),
            local: nil, cloud: nil,
            rules: StubFormatter { _ in
                usleep(200_000)
                return "CLEANED"
            })
        let mode = mode
        let running = Task { try await chain.format("hello there friend", mode: mode) }
        try await Task.sleep(for: .milliseconds(50))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    /// The other half: a request withdrawn before the chain starts must not
    /// spin up a language model at all. Cancelling a dictation should not cost
    /// a two-second inference.
    @Test("an already-cancelled caller never starts the engine")
    func cancelledCallerNeverStartsEngine() async throws {
        let chain = FormatterChain(
            engine: .local, timeout: .seconds(1),
            local: StubFormatter { _ in
                Issue.record("engine was started for an already-cancelled request")
                return "x"
            },
            cloud: nil, rules: rules)
        let mode = mode
        let running = Task { () async throws -> String in
            while !Task.isCancelled { await Task.yield() }
            return try await chain.format("hello there friend", mode: mode)
        }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
    }

    /// The guarantee the whole chain exists to make: with every engine broken,
    /// the real terminal formatter still puts words at the cursor.
    @Test("with everything broken the real rule-based formatter still returns text")
    func guaranteeHolds() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .milliseconds(50),
            local: StubFormatter { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            },
            cloud: StubFormatter { _ in throw FormatterError.transportFailure("no route") },
            rules: RuleBasedFormatter())
        #expect(try await chain.format("um so I think uh we should go", mode: mode)
                == "so I think we should go")
    }
}
