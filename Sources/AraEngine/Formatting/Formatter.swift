import Foundation

public enum FormatterError: Error, Sendable, Equatable {
    case unavailable
    case timedOut
    case implausibleOutput
    case refused
    /// The engine stopped because it ran out of token budget, not because the
    /// rewrite was finished.
    ///
    /// Its own case rather than `implausibleOutput` because the text that
    /// comes back is not implausible — it is a correct rewrite of the first
    /// part of the utterance, which is exactly what makes it dangerous. The
    /// length guard cannot catch it: a rewrite that keeps most of the words
    /// and drops the last third sits comfortably inside every ratio bound.
    /// Only the engine knows it stopped early, so only the engine can say so.
    case truncated
    case transportFailure(String)
    /// A previous request is still occupying the engine.
    ///
    /// Distinct from `timedOut` because it is the *cause* of the timeouts that
    /// would otherwise follow, and a log that cannot tell them apart sends you
    /// looking at the deadline instead of at the queue behind it.
    case busy
}

/// Rewrites a raw transcript into cleaner prose. Implementations must be
/// safe to call concurrently and must never return an empty string for
/// non-empty input.
public protocol Formatter: Sendable {
    func format(_ text: String, mode: Mode) async throws -> String
}
