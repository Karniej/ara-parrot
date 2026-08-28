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

/// Captures the `Mode` a formatter was handed.
private final class ModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: Mode?
    func set(_ new: Mode) { lock.lock(); mode = new; lock.unlock() }
    var current: Mode? { lock.lock(); defer { lock.unlock() }; return mode }
}

/// Captures the `URLRequest` a transport was handed.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ new: URLRequest) { lock.lock(); request = new; lock.unlock() }
    var current: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
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

    /// A config whose cleanup intensity actually reaches a language model.
    ///
    /// `Config()` used to default to `.medium` and these tests leaned on it.
    /// The shipped default is now `.none` — Parakeet punctuates its own output,
    /// so the daemon no longer spends a second of generation on what the
    /// transcriber already did. That is right for the product and wrong for a
    /// suite about *engine routing*: at `.none` no engine is reached at all,
    /// and every routing assertion here would pass by not running.
    ///
    /// So the intensity is stated rather than inherited. A future change to
    /// the default cannot quietly turn these into tests of nothing.
    private func llmConfig() -> Config {
        var config = Config()
        config.cleanup = .medium
        return config
    }

    private func session(_ config: Config,
                         apiKey: String? = nil,
                         mlx: (any AraCore.Formatter)? = nil,
                         apple: (any AraCore.Formatter)? = nil,
                         cloudTransport: CloudFormatter.Transport? = nil,
                         dictionaryURL: URL? = nil,
                         snippetsURL: URL? = nil)
        -> DictationSession
    {
        Pipeline.makeSession(config: config, apiKey: apiKey, mlx: mlx,
                             apple: apple, cloudTransport: cloudTransport,
                             dictionaryURL: dictionaryURL,
                             snippetsURL: snippetsURL)
    }

    /// A dictionary file with one correction, for the wiring tests.
    private func dictionaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-pipe-\(UUID().uuidString).json")
        try! #"[{"canonical": "Ara", "variants": ["arra"]}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - engine

    @Test("engine .off leaves the transcript untouched")
    func engineOff() async {
        var config = llmConfig()
        config.engine = .off
        let out = await session(config, apple: PipelineStub { _, _ in
            Issue.record("an engine ran under engine .off")
            return "x"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.filler)
    }

    @Test("engine .rules runs the rule-based formatter and no model")
    func engineRules() async {
        var config = llmConfig()
        config.engine = .rules
        let out = await session(config, apple: PipelineStub { _, _ in
            Issue.record("an engine ran under engine .rules")
            return "x"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
    }

    @Test("engine .apple routes through the Apple on-device formatter")
    func engineApple() async {
        var config = llmConfig()
        config.engine = .apple
        let out = await session(config, apple: PipelineStub { _, _ in "Hello there friend." })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == "Hello there friend.")
    }

    /// The default engine, and therefore the one a fresh install runs. A
    /// pipeline that built the chain correctly for every *named* engine while
    /// dropping the default would ship as "formatting silently does nothing".
    /// "Default engine" means `Config().engine`, which is still `.mlx`. The
    /// *intensity* is stated because the default is now `.none`, at which no
    /// engine runs at all — see `llmConfig`.
    @Test("the default engine routes through the MLX formatter")
    func defaultEngineIsMLX() async {
        // The engine default is asserted from the real `Config()`; the
        // intensity is raised because the shipped default reaches no engine.
        #expect(Config().engine == .mlx)
        let config = llmConfig()
        let out = await session(config,
                                mlx: PipelineStub { _, _ in "Hello there friend." },
                                apple: PipelineStub { _, _ in
                                    Issue.record("the Apple model ran under the default engine")
                                    return "APPLE"
                                })
            .process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == "Hello there friend.")
    }

    @Test("an unwarmed MLX formatter is not a per-utterance degradation")
    func unwarmedMLXIsSilent() async {
        let notices = SignalCounter()
        let unwarmed = MLXFormatter(
            isModelPresent: { true },
            load: {
                Issue.record("format triggered a model load")
                return { _, _ in "unused" }
            })
        let config = Config()
        let output = await Pipeline.makeSession(
            config: config, apiKey: nil, mlx: unwarmed, apple: nil,
            onDegrade: { _ in notices.bump() })
            .process(Self.filler, override: nil, manual: nil,
                     frontmostBundleID: nil)
        #expect(!output.isEmpty)
        #expect(notices.count == 0)
    }

    @Test("engine .cloud falls back to MLX, not to the Apple model")
    func cloudFallsBackToMLX() async {
        var config = llmConfig()
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

    // MARK: - cleanup

    /// `cleanup: none` must skip every model while the rules floor still runs —
    /// filler stripped, so the output proves which formatter produced it.
    @Test("cleanup none skips the model and keeps the rules floor")
    func cleanupNoneSkipsTheModel() async {
        var config = llmConfig()
        config.cleanup = .none
        let out = await session(config, mlx: PipelineStub { _, _ in
            Issue.record("a model ran under cleanup none")
            return "MODEL"
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.cleaned)
    }

    /// The configured intensity must arrive at the engine on the mode, or
    /// `TranscriptPrompt` silently formats everyone at medium — a mis-wiring
    /// with no symptom other than the wrong editing aggressiveness.
    @Test("config.cleanup reaches the formatter on the resolved mode")
    func cleanupReachesTheFormatter() async {
        var config = llmConfig()
        config.cleanup = .high
        let box = ModeBox()
        let out = await session(config, mlx: PipelineStub { text, mode in
            box.set(mode)
            return text
        }).process(Self.filler, override: nil, manual: nil, frontmostBundleID: nil)
        #expect(out == Self.filler)
        #expect(box.current?.cleanup == .high)
        #expect(box.current?.usesLLM == true)
    }

    // MARK: - timeoutMs

    /// `timeoutMs` reaching the chain is not observable from any output value —
    /// only from how long the daemon is prepared to wait. A stalled engine and a
    /// 60ms budget must produce rule-based text promptly; hard-coding a longer
    /// deadline would hang this test rather than fail an assertion.
    @Test("timeoutMs becomes the chain's per-engine deadline")
    func timeoutIsWired() async {
        var config = llmConfig()
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
        var config = llmConfig()
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
        var config = llmConfig()
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
        var config = llmConfig()
        config.engine = .apple
        // The stub echoes its input alongside the mode id, because the chain's
        // plausibility guard judges the rewrite against the transcript: a
        // reply sharing none of the speaker's words is how a translation looks
        // (`OutputGuard.abandonsVocabulary`), and a bare mode id is also too
        // short for the length ratio. Echoing keeps this a test of *routing*
        // rather than an accidental test of the guard.
        let out = await session(config,
                                apple: PipelineStub { text, mode in
                                    "\(mode.id) mode: \(text)"
                                })
            .process(Self.filler, override: nil, manual: nil,
                     frontmostBundleID: "com.apple.dt.Xcode")
        #expect(out.hasPrefix("code mode: "))
    }

    // MARK: - dictionary

    /// The file lives where the user already edits configuration.
    @Test("the dictionary file defaults to the config directory")
    func dictionaryDefaultsNextToConfig() {
        #expect(LocalDictionary.defaultURL
                == Config.defaultURL.deletingLastPathComponent()
                    .appendingPathComponent("dictionary.json"))
    }

    /// Engine `.off` consults no formatter at all, so a correction arriving
    /// anyway proves both halves at once: `makeSession` wires the URL it was
    /// given, and the dictionary runs upstream of every engine.
    @Test("makeSession wires the dictionary from the given URL")
    func dictionaryURLIsWired() async {
        var config = llmConfig()
        config.engine = .off
        let out = await session(config, dictionaryURL: dictionaryFile())
            .process("tell arra hello", override: nil, manual: nil,
                     frontmostBundleID: nil)
        #expect(out == "tell Ara hello")
    }

    /// The daemon passes a *source* rather than a URL when it has corrections
    /// that could not be written to disk (`UnsavedCorrections`); a session
    /// that quietly kept loading from the URL would drop exactly those.
    @Test("makeSession consults a custom dictionary source when given one")
    func dictionarySourceOverride() async {
        var config = llmConfig()
        config.engine = .off
        let out = await Pipeline.makeSession(
            config: config, apiKey: nil, mlx: nil, apple: nil,
            dictionary: {
                LocalDictionary(entries: [
                    .init(canonical: "Ara", variants: ["arra"]),
                ])
            })
            .process("tell arra hello", override: nil, manual: nil,
                     frontmostBundleID: nil)
        #expect(out == "tell Ara hello")
    }

    /// Corrections are about what the user said, not how it is formatted:
    /// verbatim mode skips the language model, and must not skip the
    /// dictionary with it.
    @Test("verbatim mode still gets dictionary corrections")
    func verbatimModeIsCorrected() async {
        var config = llmConfig()
        config.engine = .apple
        let out = await session(config,
                                apple: PipelineStub { _, _ in
                                    Issue.record("the language model ran in verbatim mode")
                                    return "REWRITTEN"
                                },
                                dictionaryURL: dictionaryFile())
            .process("um tell arra hello", override: "verbatim", manual: nil,
                     frontmostBundleID: nil)
        #expect(out == "tell Ara hello")
    }

    // MARK: - snippets

    /// A snippets file with one entry, for the wiring tests.
    private func snippetsFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-snip-pipe-\(UUID().uuidString).json")
        try! #"[{"trigger": "sign off formal", "expansion": "Best,\nPawel"}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Through the production assembly: `makeSession` wires the URL it was
    /// given, and a hit bypasses the engine the config asked for — the
    /// expansion reaches the injector with no formatter in between.
    @Test("makeSession wires snippets from the given URL, bypassing the engine")
    func snippetsURLIsWired() async {
        var config = llmConfig()
        config.engine = .apple
        let out = await session(config,
                                apple: PipelineStub { _, _ in
                                    Issue.record("an engine ran for a snippet hit")
                                    return "MANGLED"
                                },
                                snippetsURL: snippetsFile())
            .process("Sign off formal.", override: nil, manual: nil,
                     frontmostBundleID: nil)
        #expect(out == "Best,\nPawel")
    }

    /// A broken snippets file must cost nothing but one warning: the
    /// utterance takes the normal path, untouched.
    @Test("a broken snippets file leaves dictation unaffected")
    func brokenSnippetsFileIsHarmless() async {
        var config = llmConfig()
        config.engine = .off
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-snip-broken-\(UUID().uuidString).json")
        try! "not json at all".write(to: url, atomically: true, encoding: .utf8)
        let out = await session(config, snippetsURL: url)
            .process("sign off formal", override: nil, manual: nil,
                     frontmostBundleID: nil)
        #expect(out == "sign off formal")
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
        var config = llmConfig()
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
        var config = llmConfig()
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
        var config = llmConfig()
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
