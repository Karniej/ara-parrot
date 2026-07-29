import Foundation

/// Selects a formatting engine and guarantees a usable result.
///
/// Every path terminates in the rule-based formatter, which cannot fail, so
/// `format` never throws in practice. A stalled engine is abandoned at the
/// deadline: a dictation tool that hangs is worse than one that is
/// occasionally unpolished.
///
/// The chain per engine:
/// - `.off` — the raw transcript, untouched; no formatter is consulted.
/// - `.rules` — the rule-based formatter only.
/// - `.local` — local, then rules. Deliberately *not* cloud: a default install
///   performs no network I/O, and silently reaching for the network because
///   the local model was missing would be a privacy surprise.
/// - `.cloud` — cloud, then local, then rules.
///
/// A mode with `usesLLM == false` (verbatim dictation) skips the language
/// model entirely regardless of engine, because the user asked for their words
/// and not a rewrite of them.
public struct FormatterChain: Formatter {
    private let engine: Engine
    private let timeout: Duration
    private let local: (any Formatter)?
    private let cloud: (any Formatter)?
    private let rules: any Formatter

    public init(engine: Engine, timeout: Duration,
                local: (any Formatter)?, cloud: (any Formatter)?,
                rules: any Formatter) {
        self.engine = engine
        self.timeout = timeout
        self.local = local
        self.cloud = cloud
        self.rules = rules
    }

    public func format(_ text: String, mode: Mode) async throws -> String {
        if engine == .off { return text }
        if engine == .rules || !mode.usesLLM {
            return try await rules.format(text, mode: mode)
        }

        // Labelled so a fall-through can name the engine that failed.
        var candidates: [(label: Engine, formatter: any Formatter)] = []
        if engine == .cloud, let cloud { candidates.append((.cloud, cloud)) }
        if let local { candidates.append((.local, local)) }

        for candidate in candidates {
            do {
                return try await attempt(candidate.formatter, text: text, mode: mode)
            } catch {
                // Swallowing this silently would make "why is my dictation not
                // being cleaned up?" undebuggable: the user sees only that the
                // output looks raw, with no way to tell a missing model from a
                // timeout from a rejected rewrite. One line per fall-through,
                // on stderr, matching how the rest of the daemon reports.
                Self.note("\(candidate.label.rawValue) formatter failed "
                          + "(\(Self.describe(error))); falling back")
            }
        }
        return try await rules.format(text, mode: mode)
    }

    private func attempt(_ formatter: any Formatter, text: String,
                         mode: Mode) async throws -> String {
        let out = try await Self.withDeadline(timeout) {
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
    /// is simply orphaned and its eventual result discarded. Leaking a task is
    /// the lesser evil against never returning the user's words.
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
        case .transportFailure(let detail): return "transport failure: \(detail)"
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("formatting: \(message)\n".utf8))
    }
}
