import Foundation
import Testing
@testable import AraCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Peak simultaneous occupancy, sampled from threads that are about to block.
///
/// Deliberately lock-based rather than an actor: the whole point is to measure
/// code that blocks its thread without ever suspending, and such code cannot
/// `await`.
private final class PeakOccupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var high = 0

    func enter() {
        lock.lock()
        current += 1
        high = max(high, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return high
    }
}

private struct StubError: Error {}

/// An error whose *rendering* carries a payload. Nothing in production throws
/// one; it exists so the "only literals reach a log line" rule is tested by
/// something that would visibly break it, rather than by a type whose default
/// description happens to be harmless anyway.
private struct LeakyError: Error, CustomStringConvertible, LocalizedError {
    static let payload = "sk-ant-SECRET-and-the-users-dictated-sentence"
    var description: String { Self.payload }
    var errorDescription: String? { Self.payload }
}

@Suite("FoundationModels availability")
struct FoundationModelsAvailabilityTests {
    let mode = Mode(id: "default", name: "Default", prompt: "clean it up",
                    appBundleIDs: [], usesLLM: true)

    @Test("availability check never traps, whatever the machine state")
    func availabilityIsSafe() throws {
        guard #available(macOS 26.0, *) else { return }
        // Must return a Bool rather than crashing when Apple Intelligence
        // is disabled — that is the common case for other users.
        _ = FoundationModelsFormatter.isAvailable
    }

    @Test("formatter throws .unavailable rather than hanging when disabled")
    func throwsWhenUnavailable() async throws {
        guard #available(macOS 26.0, *) else { return }
        guard !FoundationModelsFormatter.isAvailable else { return }
        try await expectImmediateUnavailable(from: FoundationModelsFormatter())
    }

    /// The same requirement, asserted on any machine: the test above goes quiet
    /// on hardware that does have Apple Intelligence, which is precisely the
    /// hardware where a regression here would go unnoticed.
    @Test("an unavailable model is reported without waiting for it")
    func throwsImmediatelyWhenModelReportsUnavailable() async throws {
        guard #available(macOS 26.0, *) else { return }
        let formatter = FoundationModelsFormatter(
            isModelAvailable: { false },
            generate: { _, _ in
                Issue.record("generation was attempted with no model available")
                return ""
            })
        try await expectImmediateUnavailable(from: formatter)
    }

    @available(macOS 26.0, *)
    private func expectImmediateUnavailable(
        from formatter: FoundationModelsFormatter
    ) async throws {
        // Timed, because "throws" is only half the requirement: the chain gives
        // each engine a deadline, and an engine that spends it before admitting
        // it has no model delays the user's text by that much for nothing.
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
        // ~5ms measured on an idle machine, including the cold framework read.
        //
        // The budget is 1s rather than the 30ms that measurement would suggest,
        // and the gap is contention, not slack. Four suites now deliberately
        // block every core — this file's occupancy test, `PipelineTests`', and
        // both of `MLXFormatterTests`' — and swift-testing runs suites in
        // parallel, so this stopwatch is read on a machine with more runnable
        // threads than cores. Observed here at 0.15s and 0.41s while those were
        // in flight, with no change to the code under test.
        //
        // 1s still catches the regression it is for. "Waiting for a model that
        // will not arrive" is either a hang or a real generation, and a real
        // Foundation Models generation on this hardware is seconds; nothing
        // between 30ms and 1s is a plausible way for this to break.
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test("format keeps its inference call off the cooperative thread pool")
    func formatRunsInferenceOffTheCooperativePool() async throws {
        guard #available(macOS 26.0, *) else { return }
        // Drives the production `format`, not the routing helper directly: the
        // regression this guards against is the wrapper being dropped from the
        // call site, which leaves the helper perfectly intact.
        //
        // The cooperative pool is sized to the core count and does not grow for
        // threads that block, so occupancy above that count is only reachable
        // off it. The stub never suspends — that is the point: it is strictly
        // less cooperative than the real framework call is believed to be, so
        // the test cannot pass by being handled more gently than reality.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let blockers = cores * 2
        let occupancy = PeakOccupancy()
        let mode = mode
        let formatter = FoundationModelsFormatter(
            isModelAvailable: { true },
            generate: { _, _ in
                occupancy.enter()
                usleep(400_000)
                occupancy.leave()
                return "hello there, friend"
            })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<blockers {
                group.addTask {
                    _ = try? await formatter.format("hello there friend", mode: mode)
                }
            }
        }

        #expect(occupancy.peak > cores,
                "peak occupancy \(occupancy.peak) on \(cores) cores: format ran its inference on the cooperative pool")
    }

    // `wrap`, `clean` and `instructions(for:)` themselves are exercised in
    // TranscriptPromptTests.swift, which owns them now. The tests kept here
    // check the wiring: that `format` actually reaches the shared
    // `TranscriptPrompt`, not a private copy.

    @Test("format's prompt and instructions come from TranscriptPrompt, not a private copy")
    func formatUsesTheSharedPrompt() async throws {
        guard #available(macOS 26.0, *) else { return }
        let mode = Mode(id: "email", name: "Email", prompt: "MODE-SPECIFIC-RULE",
                        appBundleIDs: [], usesLLM: true)
        var captured: (instructions: String, prompt: String)?
        let formatter = FoundationModelsFormatter(
            isModelAvailable: { true },
            generate: { instructions, prompt in
                captured = (instructions, prompt)
                return "hello there, friend"
            })

        _ = try await formatter.format("hello there friend", mode: mode)

        let seen = try #require(captured)
        // Exact equality, not `.contains`: a private copy of the old wording,
        // or a hand-rolled string that merely mentions the mode prompt, would
        // pass a substring check but fail this one.
        #expect(seen.instructions == TranscriptPrompt.instructions(for: mode))
        #expect(seen.prompt == TranscriptPrompt.wrap("hello there friend"))
    }

    @Test("cancellation and formatter errors are not reported as engine faults")
    func errorTranslationPassesThroughWhatItShould() throws {
        guard #available(macOS 26.0, *) else { return }
        #expect(FoundationModelsFormatter.translate(CancellationError()) is CancellationError)
        guard case .refused? = FoundationModelsFormatter.translate(FormatterError.refused)
            as? FormatterError else {
            Issue.record("a FormatterError should pass through unchanged")
            return
        }
        guard case .transportFailure? = FoundationModelsFormatter.translate(StubError())
            as? FormatterError else {
            Issue.record("an unrecognised error should become .transportFailure")
            return
        }
    }

    /// `FormatterChain` prints the mapped error to stderr, and this daemon's
    /// stderr is routinely piped to a file. A foreign error's description is a
    /// channel its producer controls, so it is reduced to a type name.
    @Test("a foreign error's own description never reaches the log line")
    func foreignErrorIsReducedToItsTypeName() throws {
        guard #available(macOS 26.0, *) else { return }
        let detail = Self.transportDetail(FoundationModelsFormatter.translate(LeakyError()))
        #expect(detail == "LeakyError")
        #expect(detail?.contains(LeakyError.payload) == false)
    }

    #if canImport(FoundationModels)
    /// The case that matters: `guardrailViolation` fires *because of* what the
    /// user just dictated, and its `Context.debugDescription` is written by the
    /// framework. Nothing from it may be rendered.
    @Test("no GenerationError context text reaches the log line")
    func generationErrorContextIsNeverRendered() throws {
        guard #available(macOS 26.0, *) else { return }
        let secret = "MY-PRIVATE-DICTATED-SENTENCE"
        let context = LanguageModelSession.GenerationError.Context(debugDescription: secret)
        let errors: [LanguageModelSession.GenerationError] = [
            .exceededContextWindowSize(context),
            .assetsUnavailable(context),
            .guardrailViolation(context),
            .unsupportedGuide(context),
            .unsupportedLanguageOrLocale(context),
            .decodingFailure(context),
            .rateLimited(context),
            .concurrentRequests(context),
            .refusal(.init(transcriptEntries: []), context),
        ]
        for error in errors {
            let mapped = FoundationModelsFormatter.translate(error)
            guard let mapped = mapped as? FormatterError else {
                Issue.record("\(error) was not mapped onto the chain's vocabulary")
                continue
            }
            #expect(Self.transportDetail(mapped)?.contains(secret) != true,
                    "the context's debugDescription reached the rendered error")
        }
    }

    @Test("the cases the chain distinguishes keep their meaning")
    func generationErrorsKeepTheirMeaning() throws {
        guard #available(macOS 26.0, *) else { return }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "x")
        let refused = FoundationModelsFormatter.translate(
            LanguageModelSession.GenerationError.guardrailViolation(context)) as? FormatterError
        guard case .refused? = refused else {
            Issue.record("a guardrail violation is a refusal, not a transport fault")
            return
        }
        let unavailable = FoundationModelsFormatter.translate(
            LanguageModelSession.GenerationError.assetsUnavailable(context)) as? FormatterError
        guard case .unavailable? = unavailable else {
            Issue.record("missing assets mean the engine is unavailable")
            return
        }
        let rateLimited = FoundationModelsFormatter.translate(
            LanguageModelSession.GenerationError.rateLimited(context)) as? FormatterError
        #expect(Self.transportDetail(rateLimited) == "rate limited by the system model")
    }
    #endif

    private static func transportDetail(_ error: (any Error)?) -> String? {
        guard case .transportFailure(let detail)? = error as? FormatterError else { return nil }
        return detail
    }
}
