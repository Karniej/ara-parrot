import Foundation

public enum FormatterError: Error, Sendable, Equatable {
    case unavailable
    case timedOut
    case implausibleOutput
    case refused
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
