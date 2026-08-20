import Foundation

/// Selects a formatting engine and guarantees a usable result.
///
/// The exact contract, because the whole component exists to make it true:
/// **if the calling task is not cancelled, `format` returns a string.** Not
/// "usually", not "unless the model is broken" — there is no error any injected
/// formatter can throw, and no way for one to hang, that makes a non-cancelled
/// call fail. `CancellationError` is the only error it ever propagates.
///
/// Every path terminates in the rule-based formatter, and if even that throws
/// the raw transcript is returned. A stalled engine is abandoned at the
/// deadline: a dictation tool that hangs is worse than one that is occasionally
/// unpolished.
///
/// `timeout` is **per formatter, not a total budget**, and it covers the
/// rule-based floor as well as the LLM engines. Under `.cloud` a hung cloud
/// followed by a hung local costs two full timeouts before the rule based
/// formatter runs, and a hung floor a third, so the worst-case latency to the
/// cursor is `timeout` times the number of formatters consulted. That is
/// intended — each engine gets a fair chance — but it means the configured
/// value should be chosen against the slowest single engine, then multiplied to
/// sanity-check the worst case.
///
/// It is also **a base, not the whole budget**: generation time grows with the
/// length of what was dictated, so a fixed value silently withholds cleanup from
/// exactly the long, considered sentences that most need it. Each attempt gets
/// `FormatterDeadline.budget(base:characters:)` — the configured value plus a
/// measured per-character allowance, under a hard ceiling so a hung engine still
/// cannot hold the cursor indefinitely. Raising `timeoutMs` raises the whole
/// curve; the ceiling bounds it.
///
/// Cancellation is not a formatting failure. If the calling task is cancelled
/// mid-format, `CancellationError` propagates rather than being absorbed into a
/// fallback: the caller asked for the work to stop, and handing back a string
/// anyway would get it typed at the user's cursor. "Never lose the transcript"
/// is a promise about broken engines, not about abandoned work.
///
/// The test for cancellation is always *this task's* state, never the type of
/// error a formatter reported. A `CancellationError` raised by a formatter
/// while the caller is alive is that formatter's own bug and is handled like
/// any other engine failure — the transcript survives it.
///
/// The chain per engine:
/// - `.off` — the raw transcript, untouched; no formatter is consulted.
/// - `.rules` — the rule-based formatter only.
/// - `.mlx` — the bundled MLX model, then rules. The default.
/// - `.apple` — Apple's on-device model, then rules.
/// - `.cloud` — cloud, then MLX, then rules.
///
/// Neither on-device engine falls back to the other, and neither falls back to
/// cloud. A default install performs no network I/O, and silently reaching for
/// the network because a local model was missing would be a privacy surprise;
/// silently reaching for the *other* local model would be a subtler version of
/// the same thing — the user named an engine, and an install with Apple
/// Intelligence off should be told its chosen engine is unavailable rather than
/// quietly served by a different one. `.cloud` reaching for MLX is the one
/// exception, and it goes the safe direction: from the network to the machine.
///
/// A mode with `usesLLM == false` (verbatim dictation) skips the language
/// model entirely regardless of engine, because the user asked for their words
/// and not a rewrite of them.
public struct FormatterChain: Formatter {
    private let engine: Engine
    private let timeout: Duration
    private let mlx: (any Formatter)?
    private let apple: (any Formatter)?
    private let cloud: (any Formatter)?
    private let rules: any Formatter
    private let onDegrade: (@Sendable (Engine) -> Void)?

    /// - Parameter onDegrade: called with the engine that failed when an LLM
    ///   engine was tried and the chain had to finish on the rule-based floor.
    ///
    ///   The transcript still arrives — that is the chain's whole contract —
    ///   but it arrives *plainer than the user configured*, and until this
    ///   existed nothing above `FormatterChain` could tell the two apart. The
    ///   daemon returns a `String` either way, so "why is this one untidy?" had
    ///   no answer anywhere except a stderr line a menu-bar user never sees.
    ///
    ///   A closure rather than a richer return type because the contract above
    ///   is the valuable thing: `format` returns a `String` and cannot fail,
    ///   and widening it to a result type to carry a diagnostic would put that
    ///   promise behind an enum at every call site. It also keeps `AraEngine`
    ///   free of anything to depend on — a closure is not a dependency.
    ///
    ///   Never called for `.rules`, `.off`, or a verbatim mode. Those reach the
    ///   floor because the user asked them to, and reporting a degradation
    ///   there would be crying wolf on the configured behaviour.
    public init(engine: Engine, timeout: Duration,
                mlx: (any Formatter)?, apple: (any Formatter)?,
                cloud: (any Formatter)?, rules: any Formatter,
                onDegrade: (@Sendable (Engine) -> Void)? = nil) {
        self.engine = engine
        self.timeout = timeout
        self.mlx = mlx
        self.apple = apple
        self.cloud = cloud
        self.rules = rules
        self.onDegrade = onDegrade
    }

    /// The one line for a user who just got a plainer transcript than usual.
    ///
    /// It names the consequence rather than the cause, because the cause is
    /// already on stderr in more detail than a pill can hold and the user's
    /// question is "why does this look different?", not "which engine timed
    /// out?". Short enough to sit beside the overlay's waveform.
    public static func degradedNote(engine: Engine) -> String {
        "\(engine.rawValue) cleanup unavailable · basic punctuation"
    }

    public func format(_ text: String, mode: Mode) async throws -> String {
        // Don't start a model inference for a request the caller has already
        // withdrawn.
        try Task.checkCancellation()
        let result = try await route(text, mode: mode)
        // Every path converges here, and it has to: a formatter is not obliged
        // to observe cancellation, and the one that matters does not.
        // `RuleBasedFormatter` is pure string work with no suspension point, so
        // a verbatim-mode call cancelled while it ran would otherwise hand back
        // a perfectly good string for a request nobody wants — the same trap as
        // an absorbed `CancellationError`, reached without any error at all.
        try Task.checkCancellation()
        return result
    }

    private func route(_ text: String, mode: Mode) async throws -> String {
        if engine == .off { return text }
        if engine == .rules || !mode.usesLLM {
            return try await terminalFallback(text, mode: mode)
        }

        // Labelled so a fall-through can name the engine that failed.
        //
        // Written as an exhaustive switch rather than a sequence of `if`s: the
        // previous form appended the local formatter under *every* engine, so
        // adding a second local engine to it would have silently made `.apple`
        // fall through to MLX and back. A switch makes adding an engine a
        // compile error until its chain is stated.
        var candidates: [(label: Engine, formatter: any Formatter)] = []
        switch engine {
        case .mlx:
            if let mlx { candidates.append((.mlx, mlx)) }
        case .apple:
            if let apple { candidates.append((.apple, apple)) }
        case .cloud:
            if let cloud { candidates.append((.cloud, cloud)) }
            if let mlx { candidates.append((.mlx, mlx)) }
        case .rules, .off:
            // Both returned above; listed so the switch stays exhaustive.
            break
        }

        // The engine whose failure is the reason we end up on the floor. Under
        // `.cloud` two can fail; the *last* one is the one that was still
        // standing between the user and their cleanup.
        var lastFailure: Engine?
        for candidate in candidates {
            do {
                return try await attempt(candidate.formatter, text: text, mode: mode)
            } catch {
                // Checked ahead of the logging, and gated on *our* task rather
                // than on the error's type. Cancellation of this task means the
                // caller withdrew the request: the engine did nothing wrong, so
                // blaming it in the log would be a lie, and moving on to the
                // next candidate would do work nobody wants.
                //
                // Gating on `Task.isCancelled` instead of on
                // `error is CancellationError` matters in both directions. A
                // formatter can throw a `CancellationError` that has nothing to
                // do with us — one leaked from an internal task group whose
                // child was cancelled, say — and treating that as withdrawal
                // would lose a transcript the caller still wants; here it falls
                // through to the fallback like any other engine bug. And an
                // engine that maps our cancellation onto its own error type
                // still stops the chain, because what makes the request dead is
                // our cancellation, not the shape of the report.
                if Task.isCancelled { throw CancellationError() }

                // Swallowing this silently would make "why is my dictation not
                // being cleaned up?" undebuggable: the user sees only that the
                // output looks raw, with no way to tell a missing model from a
                // timeout from a rejected rewrite. One line per fall-through,
                // on stderr, matching how the rest of the daemon reports.
                Self.note("\(candidate.label.rawValue) formatter failed "
                          + "(\(Self.describe(error))); falling back")
                // An unwarmed or missing model is a standing configuration
                // fault. Startup and `ara doctor` report it once; do not arm a
                // per-utterance degradation notice forever. Keep an earlier
                // failure under `.cloud`, because that attempted engine did
                // fail for this utterance.
                if let formatterError = error as? FormatterError,
                   formatterError == .unavailable {
                    continue
                }
                lastFailure = candidate.label
            }
        }
        // Reported only when something was actually *tried* and lost. An empty
        // candidate list — engine `.mlx` with no model on disk, say — reaches
        // the floor too, but that is a standing configuration fault already
        // reported once at startup and by `ara doctor`, and re-announcing it on
        // every utterance forever would train the user to ignore the notice
        // that matters.
        if let lastFailure { onDegrade?(lastFailure) }
        return try await terminalFallback(text, mode: mode)
    }

    /// The terminal step, and the only reason the chain's central promise holds.
    ///
    /// `rules` is typed `any Formatter`, so nothing in the type system enforces
    /// "the rule-based formatter cannot fail" — that is a property of
    /// `RuleBasedFormatter`, not of the parameter, and any throwing formatter
    /// injected in its place would lose the user's transcript entirely. Catching
    /// here makes the guarantee structural: whatever is passed as `rules`, a
    /// non-cancelled call returns a string — including when what it threw was
    /// itself a `CancellationError` that had nothing to do with our caller.
    ///
    /// The deadline is applied here too, and for the same reason the catch is.
    /// "There is nothing left to fall back to" is the argument for *omitting* it,
    /// and it is backwards: there is exactly one thing left, the raw transcript,
    /// and this method already returns it when `rules` throws. Timing out is just
    /// another way for the floor to fail to produce a rewrite, and it degrades to
    /// the same place. Without this, an injected formatter that hangs hangs the
    /// dictation forever — the chain's "no way for one to hang" claim held only
    /// for the *concrete* `RuleBasedFormatter`, which is pure string work, and
    /// not for the `any Formatter` the parameter actually accepts.
    ///
    /// The cost is two unstructured tasks on the verbatim fast path, which is
    /// microseconds against a transcription measured in seconds.
    ///
    /// Cancellation of *this task* is re-thrown ahead of that fallback, so a
    /// withdrawn request never comes back as raw text pretending to be a result.
    private func terminalFallback(_ text: String, mode: Mode) async throws -> String {
        let rules = self.rules
        do {
            return try await Self.withDeadline(deadline(for: text)) {
                try await rules.format(text, mode: mode)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            Self.note("rule-based formatter failed (\(Self.describe(error))); "
                      + "returning the raw transcript")
            return text
        }
    }

    /// This attempt's budget: the configured base plus the measured allowance
    /// for how much there is to rewrite. See `FormatterDeadline`.
    private func deadline(for text: String) -> Duration {
        FormatterDeadline.budget(base: timeout, characters: text.count)
    }

    private func attempt(_ formatter: any Formatter, text: String,
                         mode: Mode) async throws -> String {
        let out = try await Self.withDeadline(deadline(for: text)) {
            try await formatter.format(text, mode: mode)
        }
        guard OutputGuard.isPlausible(input: text, output: out) else {
            throw FormatterError.implausibleOutput
        }
        return out
    }

    /// Runs `operation`, and abandons it if it has not produced a value within
    /// `duration`.
    ///
    /// Deliberately *not* a `withThrowingTaskGroup`. A task group is
    /// structured: it will not return until every child has finished, so
    /// `group.cancelAll()` only ends the wait for children that actually
    /// observe cancellation. An engine blocked in synchronous inference or in a
    /// C library waiting on a socket never reaches a suspension point, and the
    /// group then waits for it indefinitely — exactly the hang this deadline
    /// exists to prevent. Measured: with a task group, a formatter that blocks
    /// its thread for 3s returns after 3s despite an 80ms deadline.
    ///
    /// So the race is run over unstructured tasks and resolved through a
    /// one-shot stream. Whichever task reports first wins; the other's result
    /// is dropped, because `AsyncThrowingStream.Continuation` ignores
    /// everything after the first `finish`. The work task is cancelled on the
    /// way out, which stops it promptly if it is well-behaved; if it is not, it
    /// is simply orphaned and its eventual result discarded.
    ///
    /// **Requirement for engine implementors: a formatter that blocks its
    /// thread MUST run that work on its own thread or executor, never on the
    /// cooperative pool.** This is not a style preference. Orphaned blocking
    /// tasks keep occupying cooperative-pool threads, and the pool is sized to
    /// the core count, so abandonment only buys time — it does not buy safety.
    /// Measured on a 12-core machine, 40 sequential calls, 80ms deadline, an
    /// engine blocking 10s per call: calls 12, 24 and 36 each stalled ~9.16s
    /// while every other call returned on time — a 114x deadline overshoot,
    /// recurring once per pool width, because when orphans occupy every thread
    /// the caller's own timer task cannot be scheduled to fire. For a wedged
    /// local model that is eleven good utterances followed by a nine-second
    /// freeze, over and over: the exact symptom this deadline exists to
    /// prevent, deferred rather than removed. The deadline holds until
    /// outstanding orphans reach pool width and then fails completely, so
    /// keeping blocking work off the cooperative pool is what makes it real.
    private static func withDeadline<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (results, feed) = AsyncThrowingStream<T, any Error>.makeStream()

        let work = Task {
            do {
                feed.yield(try await operation())
                feed.finish()
            } catch {
                feed.finish(throwing: error)
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: duration)
            } catch {
                return // Cancelled because the work won the race; stay quiet.
            }
            feed.finish(throwing: FormatterError.timedOut)
        }
        defer {
            work.cancel()
            timer.cancel()
        }

        for try await value in results { return value }
        // The stream ended without a value, which happens only when iteration
        // was interrupted by cancellation of *this* task.
        try Task.checkCancellation()
        throw FormatterError.timedOut
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? FormatterError else { return "\(error)" }
        switch error {
        case .unavailable: return "engine unavailable"
        case .timedOut: return "timed out"
        case .implausibleOutput: return "output failed the plausibility guard"
        case .refused: return "model refused the rewrite"
        case .truncated: return "rewrite hit the token budget and stopped mid-utterance"
        case .transportFailure(let detail): return "transport failure: \(detail)"
        case .busy: return "still busy with the previous utterance"
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("formatting: \(message)\n".utf8))
    }
}
