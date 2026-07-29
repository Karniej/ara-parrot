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
