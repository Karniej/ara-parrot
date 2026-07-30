import Foundation
import Testing
@testable import AraCore

// `Formatter` is qualified throughout: Foundation exports a `Formatter` class,
// so an unqualified reference is ambiguous once this file imports both.
private struct PipelineStub: AraCore.Formatter {
    let behaviour: @Sendable (String, Mode) async throws -> String
    func format(_ text: String, mode: Mode) async throws -> String {
        try await behaviour(text, mode)
    }
}

/// Peak simultaneous occupancy, sampled from threads that are about to block.
/// Lock-based rather than an actor because the code it measures blocks its
/// thread and never suspends, so it cannot `await`.
private final class Occupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var high = 0

    func enter() { lock.lock(); current += 1; high = max(high, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return high }
}

/// Captures the `URLRequest` a transport was handed.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ new: URLRequest) { lock.lock(); request = new; lock.unlock() }
    var current: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

/// Everything the daemon decides from `config.json`, verified through the
/// pipeline it actually assembles.
///
/// `FormatterChainTests` proves the chain behaves once it is built. These prove
/// the built chain is the one the configuration asked for — the half that a
/// component test cannot see, and the half a mis-wiring lives in.
@Suite("Pipeline")
struct PipelineTests {
    private static let filler = "um hello there friend"
    private static let cleaned = "hello there friend"

    private func session(_ config: Config,
                         apiKey: String? = nil,
                         mlx: (any AraCore.Formatter)? = nil,
                         apple: (any AraCore.Formatter)? = nil,
                         cloudTransport: CloudFormatter.Transport? = nil)
        -> DictationSession
    {
        Pipeline.makeSession(config: config, apiKey: apiKey, mlx: mlx,
                             apple: apple, cloudTransport: cloudTransport)
    }

    // MARK: - engine

    @Test("engine .off leaves the transcript untouched")
    func engineOff() async {
        var config = Config()
        config.engine = .off
        let out = await session(config, apple: PipelineStub { _, _ in
            Issue.record("an engine ran under engine .off")
            return "x"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.filler)
    }

    @Test("engine .rules runs the rule-based formatter and no model")
    func engineRules() async {
        var config = Config()
        config.engine = .rules
        let out = await session(config, apple: PipelineStub { _, _ in
            Issue.record("an engine ran under engine .rules")
            return "x"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
    }

    @Test("engine .apple routes through the Apple on-device formatter")
    func engineApple() async {
        var config = Config()
        config.engine = .apple
        let out = await session(config, apple: PipelineStub { _, _ in "Hello there friend." })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == "Hello there friend.")
    }

    /// The default engine, and therefore the one a fresh install runs. A
    /// pipeline that built the chain correctly for every *named* engine while
    /// dropping the default would ship as "formatting silently does nothing".
    @Test("the default engine routes through the MLX formatter")
    func defaultEngineIsMLX() async {
        let config = Config()
        #expect(config.engine == .mlx)
        let out = await session(config,
                                mlx: PipelineStub { _, _ in "Hello there friend." },
                                apple: PipelineStub { _, _ in
                                    Issue.record("the Apple model ran under the default engine")
                                    return "APPLE"
                                })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == "Hello there friend.")
    }

    @Test("engine .cloud falls back to MLX, not to the Apple model")
    func cloudFallsBackToMLX() async {
        var config = Config()
        config.engine = .cloud
        config.cloud = CloudConfig()
        let out = await session(config,
                                apiKey: "sk-test",
                                mlx: PipelineStub { _, _ in "Hello there friend." },
                                apple: PipelineStub { _, _ in
                                    Issue.record("the Apple model ran under engine .cloud")
                                    return "APPLE"
                                },
                                cloudTransport: { _ in
                                    throw FormatterError.transportFailure("offline")
                                })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == "Hello there friend.")
    }

    // MARK: - timeoutMs

    /// `timeoutMs` reaching the chain is not observable from any output value —
    /// only from how long the daemon is prepared to wait. A stalled engine and a
    /// 60ms budget must produce rule-based text promptly; hard-coding a longer
    /// deadline would hang this test rather than fail an assertion.
    @Test("timeoutMs becomes the chain's per-engine deadline")
    func timeoutIsWired() async {
        var config = Config()
        config.engine = .apple
        config.timeoutMs = 60
        let started = ContinuousClock.now
        let out = await session(config, apple: PipelineStub { _, _ in
            try await Task.sleep(for: .seconds(30))
            return "never"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: - mode

    /// The `mode` key in `config.json` is the resolver's default. Hard-coding
    /// `"default"` here would send a verbatim install through the language model
    /// and rewrite words the user asked to keep.
    @Test("config.mode becomes the default mode")
    func configModeIsTheDefault() async {
        var config = Config()
        config.engine = .apple
        config.mode = "verbatim"
        let out = await session(config, apple: PipelineStub { _, _ in
            Issue.record("the language model ran in verbatim mode")
            return "REWRITTEN"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
    }

    @Test("a per-utterance override outranks config.mode")
    func overrideOutranksConfigMode() async {
        var config = Config()
        config.engine = .apple
        config.mode = "default"
        let out = await session(config, apple: PipelineStub { _, _ in
            Issue.record("the language model ran under a verbatim override")
            return "REWRITTEN"
        }).process(Self.filler, override: "verbatim", manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
    }

    @Test("the frontmost application still selects a mode through the built session")
    func frontmostAppSelectsMode() async {
        var config = Config()
        config.engine = .apple
        // Four words out for four words in: a bare mode id would be discarded by
        // the chain's plausibility guard before it could be asserted on.
        let out = await session(config,
                                apple: PipelineStub { _, mode in
                                    "formatted for \(mode.id) mode"
                                })
            .process(Self.filler, override: nil, manual: nil,
                     frontmostBundleID: "com.apple.dt.Xcode")
        #expect(out == "formatted for code mode")
    }

    // MARK: - executor routing

    /// Task 9 put an `actor` in front of the formatting layer, and Task 7's
    /// hardest-won property is that blocking engine work never lands on the
    /// cooperative pool — a pool sized to the core count that does not grow for
    /// blocked threads, where orphaned work stalls unrelated calls for seconds
    /// at a time. Actor isolation beats executor preference, so "does the new
    /// actor confine the engine to its own executor?" is a real question that no
    /// component test asks. It does not: `Formatter.format` is a nonisolated
    /// requirement, so it runs off the session's executor and
    /// `withTaskExecutorPreference` still applies.
    ///
    /// Measured the same way as the component test: occupancy above the core
    /// count is only reachable off the cooperative pool. The stub blocks without
    /// ever suspending, so it cannot pass by being handled more gently than a
    /// real engine would be.
    @Test("a blocking engine reached through the session stays off the cooperative pool")
    func executorRoutingSurvivesTheSessionActor() async {
        guard #available(macOS 26.0, *) else { return }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let occupancy = Occupancy()
        var config = Config()
        config.engine = .apple
        config.timeoutMs = 5_000

        let engine = FoundationModelsFormatter(
            isModelAvailable: { true },
            generate: { _, _ in
                occupancy.enter()
                usleep(400_000)
                occupancy.leave()
                return Self.cleaned
            })
        let session = session(config, apple: engine)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(cores * 2) {
                group.addTask {
                    _ = await session.process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
                }
            }
        }

        #expect(occupancy.peak > cores,
                "peak occupancy \(occupancy.peak) on \(cores) cores: the engine ran on the cooperative pool once reached through the session actor")
    }

    // MARK: - cloud

    /// A default install performs no network I/O. With no `cloud` key in the
    /// config there must be no cloud formatter to consult, even under an engine
    /// that would prefer one.
    @Test("no cloud config means no cloud formatter, even under engine .cloud")
    func noCloudConfigMeansNoNetwork() async {
        var config = Config()
        config.engine = .cloud
        config.cloud = nil
        let out = await session(config, apiKey: "sk-should-not-be-used",
                                apple: nil,
                                cloudTransport: { _ in
                                    Issue.record("a cloud request was built with no cloud config")
                                    throw FormatterError.unavailable
                                })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
    }

    /// The startup-read key has to arrive at the request, and the configured
    /// model with it. Every other symptom of a dropped credential — a chain that
    /// falls through to rules — is indistinguishable from having no cloud
    /// configured at all, so this asserts on the request itself.
    @Test("the configured cloud account and the startup-read key reach the request")
    func cloudConfigAndKeyAreWired() async throws {
        var cloudConfig = CloudConfig()
        cloudConfig.model = "claude-test-model"
        var config = Config()
        config.engine = .cloud
        config.cloud = cloudConfig

        let box = RequestBox()
        let body = #"""
        {"stop_reason":"end_turn",
         "content":[{"type":"text","text":"{\"cleaned\":\"Hello there friend.\"}"}]}
        """#

        let out = await session(config, apiKey: "sk-ant-startup-key",
                                apple: PipelineStub { _, _ in
                                    Issue.record("the local engine ran after cloud succeeded")
                                    return "LOCAL"
                                },
                                cloudTransport: { request in
                                    box.set(request)
                                    let response = HTTPURLResponse(
                                        url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
                                    return (Data(body.utf8), response)
                                })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)

        #expect(out == "Hello there friend.")
        let request = try #require(box.current)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-startup-key")
        let sent = try #require(request.httpBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["model"] as? String == "claude-test-model")
    }
}
