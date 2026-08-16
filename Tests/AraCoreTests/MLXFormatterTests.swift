import Foundation
import MLX
import Testing
@testable import AraCore

/// Peak simultaneous occupancy, sampled from threads that are about to block.
///
/// Lock-based rather than an actor, deliberately: the code being measured blocks
/// its thread and never suspends, so it cannot `await`.
private final class PeakOccupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var high = 0

    func enter() { lock.lock(); current += 1; high = max(high, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return high }
}

/// A thread-safe call counter, for asserting that something did *not* happen.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct StubError: Error {}

/// An error whose *rendering* carries a payload. Nothing in production throws
/// one; it exists so the "only literals reach a log line" rule is tested by
/// something that would visibly break it.
private struct LeakyError: Error, CustomStringConvertible, LocalizedError {
    static let payload = "the-users-dictated-sentence"
    var description: String { Self.payload }
    var errorDescription: String? { Self.payload }
}

@Suite("MLXFormatter")
struct MLXFormatterTests {
    let mode = Mode(id: "default", name: "Default", prompt: "clean it up",
                    appBundleIDs: [], usesLLM: true)

    /// A formatter whose model is present and whose load is instant, so a test
    /// can reach the post-warm-up state without touching a real model.
    private func loaded(
        generate: @escaping MLXFormatter.Generate
    ) async throws -> MLXFormatter {
        let formatter = MLXFormatter(isModelPresent: { true }, load: { generate })
        try await formatter.warmUp()
        return formatter
    }

    // MARK: - The model loads at startup, never on the dictation path

    /// The contract that makes the deadline survivable. A warm load is ~1s and a
    /// cold one ~38s against a 2500ms deadline, so a `format` that loads is a
    /// `format` that is abandoned — and an abandoned blocking task keeps its
    /// cooperative-pool thread. `format` must therefore fail fast instead.
    @Test("format throws .unavailable before warm-up, and does not wait to say so")
    func formatThrowsUnavailableBeforeWarmUp() async throws {
        let loads = Counter()
        let formatter = MLXFormatter(
            isModelPresent: { true },
            load: {
                loads.bump()
                Issue.record("format triggered a model load")
                return { _, _ in "" }
            })

        let start = ContinuousClock.now
        do {
            let out = try await formatter.format("hello there friend", mode: mode)
            Issue.record("expected .unavailable, got \(out)")
        } catch let error as FormatterError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        }
        #expect(ContinuousClock.now - start < .milliseconds(30))
        #expect(loads.count == 0)
    }

    @Test("warm-up names the download command when the model is not on disk")
    func warmUpNamesTheDownloadCommand() async throws {
        let formatter = MLXFormatter(
            isModelPresent: { false },
            load: {
                Issue.record("a load was attempted with no model on disk")
                return { _, _ in "" }
            })
        do {
            try await formatter.warmUp()
            Issue.record("expected warm-up to fail with no model present")
        } catch let error as FormatterError {
            guard case .transportFailure(let detail) = error else {
                Issue.record("expected a message naming the command, got \(error)")
                return
            }
            #expect(detail.contains(MLXModel.downloadCommand))
            #expect(detail.contains(MLXModel.id))
        }
    }

    @Test("a second warm-up does not reload")
    func warmUpIsIdempotent() async throws {
        guard #available(macOS 15.4, *) else { return }
        let loads = Counter()
        let formatter = MLXFormatter(
            isModelPresent: { true },
            load: {
                loads.bump()
                return { _, _ in "Hello there, friend." }
            })
        try await formatter.warmUp()
        try await formatter.warmUp()
        #expect(loads.count == 1)
    }

    // MARK: - Nothing model-facing touches the cooperative pool

    /// Drives the production `format`, not the routing helper: the regression
    /// this guards is the wrapper being dropped from the **call site**, which
    /// leaves the helper perfectly intact and every other test passing.
    ///
    /// The cooperative pool is sized to the core count and does not grow for
    /// threads that block, so occupancy above that count is only reachable off
    /// it. The stub never suspends — that is the point: MLX generation is
    /// compute-bound and will occupy its thread for the whole generation, so a
    /// stub that blocks is the honest model of it.
    @Test("format keeps its inference call off the cooperative thread pool")
    func formatRunsInferenceOffTheCooperativePool() async throws {
        guard #available(macOS 15.4, *) else { return }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let occupancy = PeakOccupancy()
        let mode = mode
        // One formatter per concurrent call, because a single one now admits
        // exactly one generation at a time — see the `busy` claim in `format`.
        // The routing this asserts on is unaffected: `inferenceQueue` is
        // static, so every instance lands on the same queue, and the call site
        // under test is the same production `format`.
        var formatters: [MLXFormatter] = []
        for _ in 0..<(cores + 4) {
            formatters.append(try await loaded(generate: { _, _ in
                occupancy.enter()
                usleep(150_000)
                occupancy.leave()
                return "hello there, friend"
            }))
        }

        // `cores + 4`, not `cores * 2`: enough that peak occupancy can only
        // exceed the pool width off the pool, but a smaller and shorter burst
        // of blocked threads than the ×2 the older suites use. Four suites now
        // deliberately saturate every core, and the wall-clock assertions in
        // `FoundationModelsAvailabilityTests` are measured on the same machine
        // at the same time.
        await withTaskGroup(of: Void.self) { group in
            for formatter in formatters {
                group.addTask {
                    _ = try? await formatter.format("hello there friend", mode: mode)
                }
            }
        }

        #expect(occupancy.peak > cores,
                "peak occupancy \(occupancy.peak) on \(cores) cores: format ran its inference on the cooperative pool")
    }

    /// The same requirement for the load. A cold load is 38s of compute-bound,
    /// non-suspending work; on the cooperative pool that is one core gone for
    /// the whole of startup, and `Run` warms the transcriber and then MLX
    /// sequentially inside a single detached task.
    @Test("warm-up keeps the load off the cooperative thread pool")
    func warmUpRunsTheLoadOffTheCooperativePool() async throws {
        guard #available(macOS 15.4, *) else { return }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let occupancy = PeakOccupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(cores + 4) {
                group.addTask {
                    let formatter = MLXFormatter(
                        isModelPresent: { true },
                        load: {
                            occupancy.enter()
                            usleep(150_000)
                            occupancy.leave()
                            return { _, _ in "hello there, friend" }
                        })
                    try? await formatter.warmUp()
                }
            }
        }

        #expect(occupancy.peak > cores,
                "peak occupancy \(occupancy.peak) on \(cores) cores: warm-up loaded on the cooperative pool")
    }

    // MARK: - The prompt is the shared one, and the output is cleaned

    @Test("format's prompt and instructions come from TranscriptPrompt, not a private copy")
    func formatUsesTheSharedPrompt() async throws {
        guard #available(macOS 15.4, *) else { return }
        let mode = Mode(id: "email", name: "Email", prompt: "MODE-SPECIFIC-RULE",
                        appBundleIDs: [], usesLLM: true)
        let captured = Captured()
        let formatter = try await loaded(generate: { instructions, prompt in
            captured.set(instructions: instructions, prompt: prompt)
            return "Hello there, friend."
        })

        _ = try await formatter.format("hello there friend", mode: mode)

        let seen = try #require(captured.value)
        // Exact equality, not `.contains`: a private copy of some other wording
        // that merely mentions the mode prompt would pass a substring check.
        #expect(seen.instructions == TranscriptPrompt.instructions(for: mode))
        #expect(seen.prompt == TranscriptPrompt.wrap("hello there friend"))
    }

    @Test("the model's output is cleaned of an echoed wrapper")
    func outputIsCleaned() async throws {
        guard #available(macOS 15.4, *) else { return }
        let formatter = try await loaded(generate: { _, _ in
            "\n<transcript>Hello there, friend.</transcript>\n"
        })
        let out = try await formatter.format("hello there friend", mode: mode)
        #expect(out == "Hello there, friend.")
    }

    @Test("an empty rewrite is implausible rather than a silent deletion")
    func emptyOutputIsRejected() async throws {
        guard #available(macOS 15.4, *) else { return }
        let formatter = try await loaded(generate: { _, _ in "   \n " })
        do {
            let out = try await formatter.format("hello there friend", mode: mode)
            Issue.record("expected .implausibleOutput, got \(out)")
        } catch let error as FormatterError {
            guard case .implausibleOutput = error else {
                Issue.record("expected .implausibleOutput, got \(error)")
                return
            }
        }
    }

    // MARK: - Throw, never hang

    @Test("a generation failure becomes a FormatterError the chain can fall back from")
    func generationFailureIsMapped() async throws {
        guard #available(macOS 15.4, *) else { return }
        let formatter = try await loaded(generate: { _, _ in throw StubError() })
        do {
            _ = try await formatter.format("hello there friend", mode: mode)
            Issue.record("expected a FormatterError")
        } catch let error as FormatterError {
            guard case .transportFailure(let detail) = error else {
                Issue.record("expected .transportFailure, got \(error)")
                return
            }
            #expect(detail == "StubError")
        }
    }

    /// `FormatterChain` prints the mapped error to stderr, and this daemon's
    /// stderr is routinely piped to a file. A foreign error's description is a
    /// channel its producer controls, so it is reduced to a type name.
    @Test("a foreign error's own description never reaches the log line")
    func foreignErrorIsReducedToItsTypeName() async throws {
        guard #available(macOS 15.4, *) else { return }
        let formatter = try await loaded(generate: { _, _ in throw LeakyError() })
        do {
            _ = try await formatter.format("hello there friend", mode: mode)
            Issue.record("expected a FormatterError")
        } catch let error as FormatterError {
            guard case .transportFailure(let detail) = error else {
                Issue.record("expected .transportFailure, got \(error)")
                return
            }
            #expect(detail == "LeakyError")
            #expect(!detail.contains(LeakyError.payload))
        }
    }

    /// The chain decides cancellation by `Task.isCancelled`, never by error
    /// type — but it can only do that if `format` stops and reports instead of
    /// absorbing the withdrawal into a rewrite.
    @Test("cancellation propagates out of format")
    func cancellationPropagates() async throws {
        guard #available(macOS 15.4, *) else { return }
        let formatter = try await loaded(generate: { _, _ in
            try await Task.sleep(for: .seconds(30))
            return "never"
        })
        let mode = mode
        let task = Task {
            try await formatter.format("hello there friend", mode: mode)
        }
        // Give the generate stub time to reach its suspension point.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        switch result {
        case .success(let out):
            Issue.record("a cancelled format returned \(out)")
        case .failure(let error):
            #expect(error is CancellationError,
                    "a withdrawn request was reported as \(type(of: error))")
        }
    }

    /// MLX's default error handler prints and calls `exit(-1)`, so every
    /// model-facing call is wrapped in a `withError` scope that converts MLX
    /// errors into thrown `MLXError`s, and `runtimeFailure` maps those onto the
    /// chain's vocabulary. One case keeps a whole sentence: the missing Metal
    /// library, which is the state every plain `swift build` binary is in.
    /// The MLX message is classified, never quoted — the rendered string is a
    /// literal naming the build script.
    @Test("a missing metallib maps to the message naming the build script")
    func missingMetallibIsNamed() {
        let mapped = MLXFormatter.runtimeFailure(
            .caught("Failed to load the default metallib. library not found"))
        guard case .transportFailure(let detail) = mapped else {
            Issue.record("expected .transportFailure, got \(mapped)")
            return
        }
        #expect(detail == MLXFormatter.missingMetallibMessage)
        #expect(detail.contains(MLXRuntime.buildCommand))
        // Classified, not quoted: nothing of MLX's own rendering survives.
        #expect(!detail.contains("library not found"))
    }

    @Test("any other MLX runtime error is reduced to its type name")
    func otherMLXErrorsAreReducedToTheTypeName() {
        let mapped = MLXFormatter.runtimeFailure(
            .caught("[matmul] Last dimension of first input with shape /Users/someone/secret"))
        guard case .transportFailure(let detail) = mapped else {
            Issue.record("expected .transportFailure, got \(mapped)")
            return
        }
        if MLXRuntime.metallibIsLocatable {
            #expect(detail == "MLXError")
        } else {
            // With no metallib findable, every MLX failure is attributed to it
            // — the second signal in `runtimeFailure`'s classification, and on
            // such a machine almost certainly the true cause.
            #expect(detail == MLXFormatter.missingMetallibMessage)
        }
        #expect(!detail.contains("secret"))
    }

    @Test("FormatterErrors and cancellation pass through translation untouched")
    func translationPassesThroughWhatItShould() {
        #expect(MLXFormatter.translate(CancellationError()) is CancellationError)
        guard case .refused? = MLXFormatter.translate(FormatterError.refused)
            as? FormatterError else {
            Issue.record("a FormatterError should pass through unchanged")
            return
        }
    }

    // MARK: - Where the model lives

    /// The one-time download must land in the cache the daemon already uses for
    /// Whisper weights, not a second one — a user who has run
    /// `ara models download` should not discover a separate multi-gigabyte
    /// directory somewhere else.
    @Test("the model directory sits in the same hub cache as the Whisper models")
    func modelDirectoryIsTheWhisperCache() {
        let path = MLXModel.directory.path
        #expect(path.hasSuffix("huggingface/models/\(MLXModel.id)"),
                "unexpected model directory: \(path)")
    }
}

/// Captures the arguments the generate step was handed.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (instructions: String, prompt: String)?
    func set(instructions: String, prompt: String) {
        lock.lock(); stored = (instructions, prompt); lock.unlock()
    }
    var value: (instructions: String, prompt: String)? {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

/// The pile-up the `busy` claim exists to prevent.
///
/// The field report that produced it: formatting timed out on transcripts of
/// 208, 6 and 3 characters in succession, then recovered on its own. No
/// deadline explains a 3-character timeout — what explains it is that the
/// chain's deadline abandons the *wait* while the generation keeps holding the
/// GPU, so each abandoned utterance made the next one slower.
@Suite("MLXFormatterConcurrency")
struct MLXFormatterConcurrencyTests {
    let mode = Mode(id: "default", name: "Default", prompt: "clean it up",
                    appBundleIDs: [], usesLLM: true)

    @Test("a second utterance is refused while the first still holds the engine")
    func refusesWhileBusy() async throws {
        let released = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let formatter = MLXFormatter(isModelPresent: { true }, load: {
            { _, _ in
                entered.signal()
                // Stands in for a generation the chain has already abandoned:
                // still running, still holding the engine.
                released.wait()
                return "first"
            }
        })
        try await formatter.warmUp()

        let first = Task { try await formatter.format("first", mode: self.mode) }
        entered.wait()

        await #expect(throws: FormatterError.busy) {
            try await formatter.format("second", mode: self.mode)
        }

        released.signal()
        #expect(try await first.value == "first")
    }

    /// The claim must be released by the work finishing, not by the caller
    /// giving up — otherwise one overrun would disable cleanup until restart.
    @Test("the engine is usable again once the previous generation returns")
    func recoversAfterTheGenerationFinishes() async throws {
        let formatter = MLXFormatter(isModelPresent: { true },
                                     load: { { _, _ in "done" } })
        try await formatter.warmUp()
        #expect(try await formatter.format("one", mode: mode) == "done")
        #expect(try await formatter.format("two", mode: mode) == "done")
        #expect(try await formatter.format("three", mode: mode) == "done")
    }

    /// A refusal must be distinguishable from "no model", because the two call
    /// for opposite responses: one is transient, the other needs a download.
    @Test("busy is not reported as unavailable")
    func busyIsNotUnavailable() async throws {
        let released = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let formatter = MLXFormatter(isModelPresent: { true }, load: {
            { _, _ in entered.signal(); released.wait(); return "x" }
        })
        try await formatter.warmUp()
        let first = Task { try await formatter.format("a", mode: self.mode) }
        entered.wait()
        do {
            _ = try await formatter.format("b", mode: mode)
            Issue.record("expected a refusal")
        } catch let error as FormatterError {
            #expect(error != .unavailable)
            #expect(error == .busy)
        }
        released.signal()
        _ = try await first.value
    }

    @Test("overrun callbacks use the configured timeout base")
    func overrunCallbackUsesConfiguredBase() async throws {
        guard #available(macOS 15.4, *) else { return }
        let tight = Counter()
        let tightFormatter = MLXFormatter(
            isModelPresent: { true },
            load: {
                { _, _ in
                    try await Task.sleep(for: .milliseconds(80))
                    return "cleaned"
                }
            },
            deadlineBase: .milliseconds(10),
            onOverrun: tight.bump)
        try await tightFormatter.warmUp()
        _ = try await tightFormatter.format("short", mode: mode)
        #expect(tight.count == 1)

        let loose = Counter()
        let looseFormatter = MLXFormatter(
            isModelPresent: { true },
            load: { { _, _ in "cleaned" } },
            deadlineBase: .seconds(1),
            onOverrun: loose.bump)
        try await looseFormatter.warmUp()
        _ = try await looseFormatter.format("short", mode: mode)
        #expect(loose.count == 0)
    }
}

/// The token budget, which is the whole of the "long dictation loses words"
/// fix that can be tested without a GPU.
@Suite("MLXFormatter token budget")
struct MLXFormatterBudgetTests {
    @Test("short utterances keep the original 512-token floor")
    func floorHolds() {
        #expect(MLXFormatter.maxTokens(forCharacters: 0) == 512)
        #expect(MLXFormatter.maxTokens(forCharacters: 40) == 512)
        // The floor binds right up to where scaling overtakes it.
        #expect(MLXFormatter.maxTokens(forCharacters: 767) == 512)
    }

    @Test("a long dictation gets more room than the old flat budget")
    func scalesWithInput() {
        // ~2 minutes of speech. Under the old flat 512 this was the case that
        // stopped mid-sentence and had its ending typed away.
        let twoMinutes = MLXFormatter.maxTokens(forCharacters: 1_800)
        #expect(twoMinutes == 1_028)
        #expect(twoMinutes > 512)
    }

    @Test("the ceiling still bounds a model stuck in a loop")
    func ceilingHolds() {
        #expect(MLXFormatter.maxTokens(forCharacters: 10_000) == 2_048)
        #expect(MLXFormatter.maxTokens(forCharacters: .max) == 2_048)
    }

    @Test("a negative count cannot produce a negative budget")
    func negativeInput() {
        #expect(MLXFormatter.maxTokens(forCharacters: -100) == 512)
    }
}
