import Foundation

public enum FormatterError: Error, Sendable {
    case unavailable
    case timedOut
    case implausibleOutput
    case refused
    case transportFailure(String)
}

/// Rewrites a raw transcript into cleaner prose. Implementations must be
/// safe to call concurrently and must never return an empty string for
/// non-empty input.
public protocol Formatter: Sendable {
    func format(_ text: String, mode: Mode) async throws -> String
}
