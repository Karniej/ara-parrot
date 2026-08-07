import Dispatch
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device formatting via Apple's built-in language model.
///
/// Requires macOS 26 with Apple Intelligence enabled. When it is unavailable
/// the formatter throws `.unavailable` promptly so the chain can fall through —
/// it never blocks waiting for a model that will not arrive.
///
/// The `#if canImport` guards keep the file compiling on a toolchain whose SDK
/// predates the framework; there the type exists but is permanently
/// unavailable.
///
/// ## The transcript is data
///
/// Everything this formatter is handed was spoken by a user who wanted it typed
/// at their cursor, which makes "please summarise the last email" a *string to
/// punctuate*, not a request. The instructions say so explicitly and the
/// transcript is wrapped in a tag so its boundaries are unambiguous; `wrap`
/// escapes any closing tag inside the text so it cannot end the wrapper early,
/// and `clean` removes the wrapper if the model echoes it, because a stray
/// `<transcript>` typed into the user's document is exactly the failure the
/// wrapper is supposed to prevent.
///
/// ## Everything model-facing runs off the cooperative pool
///
/// Both the availability check and the generation call are framework work of
/// unbounded synchronous cost, so both happen inside `runOffCooperativePool`.
/// See that method for why this is a correctness requirement rather than
/// tidiness.
@available(macOS 26.0, *)
public struct FoundationModelsFormatter: AraEngine.Formatter {
    /// The single model-facing step, injectable so tests can drive the real
    /// `format` path — including its executor routing and its error mapping —
    /// on a machine where no model exists. Everything outside this closure is
    /// production code in every configuration.
    typealias Generate = @Sendable (_ instructions: String, _ prompt: String) async throws -> String

    private let isModelAvailable: @Sendable () -> Bool
    private let generate: Generate

    public init() {
        self.init(isModelAvailable: { Self.isAvailable }, generate: Self.respondWithSystemModel)
    }

    init(isModelAvailable: @escaping @Sendable () -> Bool, generate: @escaping Generate) {
        self.isModelAvailable = isModelAvailable
        self.generate = generate
    }

    /// Whether the system model can be asked for a rewrite right now.
    ///
    /// Never traps, on any machine state — most users have Apple Intelligence
    /// switched off, and this property is what the daemon consults before it
    /// decides that "local formatting" means anything.
    ///
    /// It is not free, and it is not a cached flag. Measured on a machine with
    /// Apple Intelligence disabled: ~3.3ms to construct `SystemLanguageModel`
    /// plus ~3.1ms for the first `availability` read, then ~0.001ms for every
    /// read after. That is synchronous framework work on the calling thread,
    /// and the cost on eligible-but-still-downloading hardware
    /// (`.modelNotReady`) is unmeasured and could be worse. `format` therefore
    /// reads it inside `runOffCooperativePool` rather than ahead of it; a
    /// caller invoking this property directly — Doctor, or startup wiring —
    /// pays that cost on its own thread, which is fine at startup and would not
    /// be on the dictation path.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    /// Why the system model cannot be asked for a rewrite, or `nil` when it can.
    ///
    /// The same read as `isAvailable`, carrying the reason instead of discarding
    /// it. `doctor` is the one place the reason matters: with Apple Intelligence
    /// off, `Pipeline.localFormatter()` returns `nil`, so there is no local
    /// candidate in the chain at all and therefore no fall-through line either —
    /// the user sees plainer text and nothing anywhere explains why. Every
    /// string returned is a literal in this file; nothing from the framework's
    /// own error rendering is passed through.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "this Mac is not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off"
            case .modelNotReady:
                return "the on-device model is not ready yet (still downloading?)"
            @unknown default:
                return "unavailable for an unrecognised reason"
            }
        }
        #else
        return "this binary was built against an SDK without FoundationModels"
        #endif
    }

    public func format(_ text: String, mode: Mode) async throws -> String {
        // Pure string work, cheap, and safe anywhere.
        let instructions = TranscriptPrompt.instructions(for: mode)
        let prompt = TranscriptPrompt.wrap(text)

        let available = isModelAvailable
        let generate = self.generate

        let raw: String
        do {
            raw = try await Self.runOffCooperativePool {
                // Inside the routing, not ahead of it: reading availability is
                // itself a synchronous framework call.
                guard available() else { throw FormatterError.unavailable }
                return try await generate(instructions, prompt)
            }
        } catch {
            throw Self.translate(error)
        }

        let cleaned = TranscriptPrompt.clean(raw)
        guard !cleaned.isEmpty else { throw FormatterError.implausibleOutput }
        return cleaned
    }

    // MARK: - The model-facing step

    #if canImport(FoundationModels)
    private static let respondWithSystemModel: Generate = { instructions, prompt in
        // A fresh session per call: sessions accumulate a transcript, and one
        // utterance must not condition the rewrite of the next. Note that this
        // construction is itself expensive — ~26.7ms of synchronous work on a
        // cold first call — which is reason enough for the executor routing
        // even if `respond(to:)` never blocks at all.
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }
    #else
    private static let respondWithSystemModel: Generate = { _, _ in
        throw FormatterError.unavailable
    }
    #endif

    // MARK: - Staying off the cooperative pool

    /// The thread pool inference runs on, which is deliberately *not* the
    /// cooperative one. Concurrent rather than serial so a wedged call delays
    /// only itself; libdispatch grows this pool when its threads block, which
    /// is the property the cooperative pool specifically does not have.
    private static let inferenceQueue = DispatchQueue(
        label: "ara.formatting.foundation-models",
        qos: .userInitiated,
        attributes: .concurrent)

    /// Runs `body` with the inference queue as the task's executor preference,
    /// so anything in it that blocks a thread blocks one of ours.
    ///
    /// `FormatterChain.withDeadline` abandons a slow formatter rather than
    /// cancelling it, because unstructured work cannot be cancelled from
    /// outside — and an abandoned task that blocks its thread keeps occupying
    /// the cooperative pool, which is sized to the core count and never grows.
    /// Measured previously in this project: with a blocking engine on a 12-core
    /// machine, every twelfth call stalled ~9.16s against an 80ms deadline. The
    /// chain's doc comment states the resulting rule — a formatter that blocks
    /// its thread must not do it on the cooperative pool — and this is where
    /// this formatter obeys it.
    ///
    /// It is not settled that `respond(to:)` ever blocks for long. Generation
    /// happens out of process, in `TGOnDeviceInferenceProviderService`, reached
    /// over XPC, and none of `FoundationModels`, `TokenGeneration` or
    /// `GenerativeModels` imports a synchronous XPC-reply or semaphore-wait
    /// symbol. But that only covers the round trip, not the synchronous work
    /// wrapped around it, and none of the FoundationModels entry points hops to
    /// an internal executor: whatever they do synchronously is charged to the
    /// calling thread. Two measurements settle it without needing to resolve
    /// the question — `LanguageModelSession(instructions:)` costs ~26.7ms cold,
    /// and the availability read ~5ms cold. Both are far too much to spend on a
    /// pool thread that other subsystems need, and the cost of being wrong in
    /// the other direction is one dispatch queue.
    ///
    /// Verified on this machine rather than assumed: entering the preference
    /// puts execution on the queue immediately and keeps it there across
    /// `await`s, and 24 thread-blocking bodies on a 12-core machine complete in
    /// 2.01s through this helper versus 4.16s — two full waves of pool width —
    /// without it.
    ///
    /// **Precondition: the caller must be nonisolated.** Actor isolation beats
    /// executor preference, so from a `@MainActor` caller this moves nothing,
    /// and `respond(to:)` — being `nonisolated(nonsending)` — then runs its
    /// synchronous work on the *main thread*, which is worse than the problem
    /// being solved. `FormatterChain` satisfies this today: `format` is
    /// nonisolated and the chain invokes it through an `@escaping @Sendable`
    /// closure in an unstructured task. A future MainActor caller must hop off
    /// the main actor before calling `format`.
    ///
    /// The guarantee also covers only work reachable from `body`'s own task.
    /// Executor preference is not inherited by unstructured `Task { }`s created
    /// inside it, so if the framework ever spawns one and blocks in it, that
    /// lands back on the cooperative pool and there is nothing this can do
    /// about it.
    static func runOffCooperativePool<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskExecutorPreference(inferenceQueue) {
            try await body()
        }
    }

    // MARK: - Error mapping

    /// Maps failures onto the chain's vocabulary. The chain logs the mapped
    /// error before falling back, so the distinction is what tells a user "the
    /// model declined this text" apart from "the model is broken".
    ///
    /// ## Every rendered string is a literal in this file
    ///
    /// The same rule `CloudFormatter.translate` follows, and for a sharper
    /// reason here. `GenerationError` is a `LocalizedError` whose every case
    /// carries a `Context` with a framework-authored `debugDescription`, and the
    /// case most likely to fire is `guardrailViolation` — raised *because of*
    /// what the user just dictated. `localizedDescription` reads
    /// `NSLocalizedDescriptionKey` out of the error, so an implementation that
    /// quoted the offending input would put the user's speech into a daemon log
    /// that is routinely piped to a file. The switch below is exhaustive over
    /// the nine documented cases so that adding one is a compile error rather
    /// than a silent fall-through to whatever the framework wants to say, and
    /// anything foreign is reduced to its type name.
    ///
    /// ## The cancellation passthrough is decorative
    ///
    /// `FormatterError` and `CancellationError` pass through untouched, but not
    /// because that protects the user's withdrawal from being logged as an
    /// engine fault — `FormatterChain` decides cancellation by
    /// `Task.isCancelled` and never by error type, so the rendering is not what
    /// the chain reads. When our caller *is* cancelled the chain rethrows before
    /// this error is ever described; when it is not, a `CancellationError`
    /// arriving from the model is that engine's own bug and is handled like any
    /// other engine failure, transcript intact. The passthrough earns its place
    /// as the honest rendering of the error, not as a fix for anything
    /// observable today.
    static func translate(_ error: any Error) -> any Error {
        if let error = error as? FormatterError { return error }
        if error is CancellationError { return error }
        #if canImport(FoundationModels)
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                return FormatterError.refused
            case .assetsUnavailable:
                return FormatterError.unavailable
            case .exceededContextWindowSize:
                return FormatterError.transportFailure("transcript exceeded the context window")
            case .unsupportedGuide:
                return FormatterError.transportFailure("unsupported generation guide")
            case .unsupportedLanguageOrLocale:
                return FormatterError.transportFailure("unsupported language or locale")
            case .decodingFailure:
                return FormatterError.transportFailure("could not decode the model's response")
            case .rateLimited:
                return FormatterError.transportFailure("rate limited by the system model")
            case .concurrentRequests:
                return FormatterError.transportFailure("too many concurrent model requests")
            @unknown default:
                return FormatterError.transportFailure("unclassified generation error")
            }
        }
        #endif
        return FormatterError.transportFailure("\(type(of: error))")
    }
}
