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

/// Collects the engines the chain reported as degraded.
private final class DegradeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [Engine] = []
    var recorded: [Engine] { lock.withLock { engines } }
    var record: @Sendable (Engine) -> Void {
        { [self] engine in lock.withLock { engines.append(engine) } }
    }
}

@Suite("FormatterChain")
struct FormatterChainTests {
    let mode = Mode(id: "default", name: "Default", prompt: "p",
                    appBundleIDs: [], usesLLM: true)
    fileprivate let rules = StubFormatter { _ in "RULES" }

    @Test("apple engine uses the Apple model when it succeeds")
    func localSucceeds() async throws {
        let chain = FormatterChain(
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in "one two three four" },
            cloud: nil, rules: rules)
        #expect(try await chain.format("one two three four five", mode: mode)
                == "one two three four")
    }

    @Test("apple failure falls through to rules")
    func localFallsBack() async throws {
        let chain = FormatterChain(
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    @Test("a hung formatter is abandoned at the deadline")
    func deadlineFires() async throws {
        let chain = FormatterChain(
            engine: .apple, timeout: .milliseconds(80),
            mlx: nil, apple: StubFormatter { _ in
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
            engine: .apple, timeout: .milliseconds(80),
            mlx: nil, apple: StubFormatter { _ in
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
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in "Paris" },
            cloud: nil, rules: rules)
        #expect(try await chain.format("what is the capital of France", mode: mode)
                == "RULES")
    }

    @Test("cloud engine falls through cloud, then mlx, then rules")
    func cloudChain() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            mlx: StubFormatter { _ in throw FormatterError.unavailable },
            apple: nil,
            cloud: StubFormatter { _ in throw FormatterError.refused },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    // MARK: - the engines the MLX formatter added

    @Test("mlx engine uses mlx when it succeeds")
    func mlxSucceeds() async throws {
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: StubFormatter { _ in "one two three four" },
            apple: nil, cloud: nil, rules: rules)
        #expect(try await chain.format("one two three four five", mode: mode)
                == "one two three four")
    }

    @Test("mlx failure falls through to rules")
    func mlxFallsBack() async throws {
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: StubFormatter { _ in throw FormatterError.unavailable },
            apple: nil, cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    /// The user named an engine. An install with the MLX model missing should
    /// be told its chosen engine is unavailable — one stderr line per
    /// utterance — not quietly served by a different local model whose output
    /// and privacy properties they did not ask for.
    @Test("mlx engine never reaches for the Apple model, or for cloud")
    func mlxNeverUsesAnotherEngine() async throws {
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: StubFormatter { _ in throw FormatterError.unavailable },
            apple: StubFormatter { _ in
                Issue.record("the Apple model was called under the mlx engine")
                return "APPLE"
            },
            cloud: StubFormatter { _ in
                Issue.record("cloud was called under the mlx engine")
                return "CLOUD"
            },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    /// The mirror image, and the one the switch in `route` exists to protect:
    /// the previous implementation appended the local formatter under every
    /// engine, so a second local engine bolted onto it would have made `apple`
    /// fall through to MLX for free.
    @Test("apple engine never reaches for mlx")
    func appleNeverUsesMLX() async throws {
        let chain = FormatterChain(
            engine: .apple, timeout: .seconds(1),
            mlx: StubFormatter { _ in
                Issue.record("mlx was called under the apple engine")
                return "MLX"
            },
            apple: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    @Test("cloud engine prefers cloud over mlx when it succeeds")
    func cloudPreferredOverMLX() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            mlx: StubFormatter { _ in
                Issue.record("mlx was called after cloud succeeded")
                return "MLX"
            },
            apple: nil,
            cloud: StubFormatter { _ in "hello there friend." },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend.")
    }

    @Test("cloud engine falls back to mlx before rules")
    func cloudFallsBackToMLX() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            mlx: StubFormatter { _ in "hello there friend." },
            apple: nil,
            cloud: StubFormatter { _ in throw FormatterError.transportFailure("offline") },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend.")
    }

    /// A default install performs no network I/O, so `.apple` must never reach
    /// for a cloud formatter even when one is configured and available.
    @Test("apple engine never reaches for cloud")
    func localNeverUsesCloud() async throws {
        let chain = FormatterChain(
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in throw FormatterError.unavailable },
            cloud: StubFormatter { _ in
                Issue.record("cloud was called under the apple engine")
                return "CLOUD"
            },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
    }

    @Test("cloud engine prefers cloud when it succeeds")
    func cloudPreferred() async throws {
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            mlx: StubFormatter { _ in
                Issue.record("mlx was called after cloud succeeded")
                return "MLX"
            }, apple: nil,
            cloud: StubFormatter { _ in "hello there friend." },
            rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode)
                == "hello there friend.")
    }

    @Test("rules engine uses the rule-based formatter directly")
    func rulesEngine() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in
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
            mlx: nil, apple: StubFormatter { _ in "formatted" }, cloud: nil, rules: rules)
        #expect(try await chain.format("raw text here", mode: mode) == "raw text here")
    }

    @Test("verbatim mode never reaches the LLM")
    func verbatimSkipsLLM() async throws {
        let verbatim = Mode(id: "verbatim", name: "V", prompt: "",
                            appBundleIDs: [], usesLLM: false)
        let chain = FormatterChain(
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in Issue.record("LLM was called"); return "x" },
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
            mlx: nil, apple: StubFormatter { _ in
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
            mlx: nil, apple: nil, cloud: nil,
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
            engine: .apple, timeout: .milliseconds(50),
            mlx: nil, apple: StubFormatter { _ in
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
            engine: .apple, timeout: .seconds(30),
            mlx: nil, apple: StubFormatter { _ in "one two three four" },
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
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in throw FormatterError.unavailable },
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
            mlx: nil, apple: nil, cloud: nil,
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
            engine: .apple, timeout: .milliseconds(60),
            mlx: nil, apple: nil, cloud: nil,
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
            mlx: nil, apple: nil, cloud: nil,
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
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in throw CancellationError() },
            cloud: nil, rules: rules)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(!Task.isCancelled)
    }

    @Test("a stray CancellationError from rules does not lose the transcript")
    func strayCancellationFromRulesFallsThrough() async throws {
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(1),
            mlx: nil, apple: nil, cloud: nil,
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
            mlx: nil, apple: nil, cloud: nil,
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
            engine: .apple, timeout: .seconds(1),
            mlx: nil, apple: StubFormatter { _ in
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
            mlx: nil, apple: StubFormatter { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            },
            cloud: StubFormatter { _ in throw FormatterError.transportFailure("no route") },
            rules: RuleBasedFormatter())
        #expect(try await chain.format("um so I think uh we should go", mode: mode)
                == "so I think we should go")
    }

    // MARK: - reporting a degraded result

    /// The gap this closes: `format` returns a `String` either way, so before
    /// this signal existed nothing above the chain could tell a cleaned
    /// transcript from a floor-formatted one, and "why is this one untidy?" had
    /// no answer outside a stderr line a menu-bar user never sees.
    @Test("a failed engine is reported as a degradation")
    func failureIsReported() async throws {
        let probe = DegradeProbe()
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: StubFormatter { _ in throw FormatterError.timedOut },
            apple: nil, cloud: nil, rules: rules, onDegrade: probe.record)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(probe.recorded == [.mlx])
    }

    @Test("a successful engine reports nothing")
    func successIsSilent() async throws {
        let probe = DegradeProbe()
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: StubFormatter { _ in "cleaned up" },
            apple: nil, cloud: nil, rules: rules, onDegrade: probe.record)
        #expect(try await chain.format("hello there friend", mode: mode) == "cleaned up")
        #expect(probe.recorded.isEmpty)
    }

    /// The user configured the floor. Announcing it as a failure every time
    /// would be crying wolf on the behaviour they asked for.
    @Test("the rules engine is not a degradation")
    func rulesEngineIsSilent() async throws {
        let probe = DegradeProbe()
        let chain = FormatterChain(
            engine: .rules, timeout: .seconds(1),
            mlx: nil, apple: nil, cloud: nil, rules: rules, onDegrade: probe.record)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(probe.recorded.isEmpty)
    }

    /// Same argument: the user asked for their words, not a rewrite of them.
    @Test("a verbatim mode is not a degradation")
    func verbatimModeIsSilent() async throws {
        let probe = DegradeProbe()
        let verbatim = Mode(id: "verbatim", name: "Verbatim", prompt: "",
                            appBundleIDs: [], usesLLM: false)
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: StubFormatter { _ in throw FormatterError.timedOut },
            apple: nil, cloud: nil, rules: rules, onDegrade: probe.record)
        #expect(try await chain.format("hello there friend", mode: verbatim) == "RULES")
        #expect(probe.recorded.isEmpty)
    }

    /// A standing configuration fault — engine `.mlx` with no model on disk —
    /// is already reported at startup and by `ara doctor`. Repeating it on
    /// every utterance forever would train the user to ignore the notice.
    @Test("an engine that was never there is not reported per utterance")
    func missingEngineIsSilent() async throws {
        let probe = DegradeProbe()
        let chain = FormatterChain(
            engine: .mlx, timeout: .seconds(1),
            mlx: nil, apple: nil, cloud: nil, rules: rules, onDegrade: probe.record)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(probe.recorded.isEmpty)
    }

    /// Under `.cloud` two engines can fail. The one worth naming is the last —
    /// the one still standing between the user and their cleanup.
    @Test("the last engine to fail is the one reported")
    func lastFailureWins() async throws {
        let probe = DegradeProbe()
        let chain = FormatterChain(
            engine: .cloud, timeout: .seconds(1),
            mlx: StubFormatter { _ in throw FormatterError.timedOut },
            apple: nil,
            cloud: StubFormatter { _ in throw FormatterError.transportFailure("offline") },
            rules: rules, onDegrade: probe.record)
        #expect(try await chain.format("hello there friend", mode: mode) == "RULES")
        #expect(probe.recorded == [.mlx])
    }

    @Test("the note names the engine and the consequence")
    func degradedNoteWording() {
        let note = FormatterChain.degradedNote(engine: .mlx)
        #expect(note == "mlx cleanup unavailable · basic punctuation")
        // Short enough to sit beside the overlay's waveform.
        #expect(note.count <= 60)
    }
}
