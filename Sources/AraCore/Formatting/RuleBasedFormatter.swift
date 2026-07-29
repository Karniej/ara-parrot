import Foundation

/// The terminal fallback: deterministic, dependency-free, and incapable of
/// failing. Strips standalone filler words and collapses whitespace. If the
/// result would be empty, the original is returned — losing the user's words
/// is worse than leaving an "um" in.
public struct RuleBasedFormatter: Formatter {
    private static let filler = ["um", "uh", "erm", "ah", "you know", "i mean", "like"]

    public init() {}

    public func format(_ text: String, mode: Mode) async throws -> String {
        var out = text
        for word in Self.filler {
            // \b guards against matching inside "drum" or "humming".
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            out = out.replacingOccurrences(
                of: pattern, with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? text : out
    }
}
