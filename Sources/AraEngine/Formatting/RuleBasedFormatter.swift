import Foundation

/// The terminal fallback: deterministic, dependency-free, and incapable of
/// failing. Strips standalone filler words and collapses whitespace. The
/// filler list is deliberately short — only words that are never
/// content-bearing in English. Anything that needs judgement about whether a
/// word is filler or meaningful (like "like", "you know", "I mean", "ah" vs.
/// the unit "Ah") belongs to the language-model formatters, not this floor.
/// If the result would be empty *or* left with no letters or digits (just
/// stray punctuation), the original is returned unchanged — losing or
/// mangling the user's words is worse than leaving a filler word in.
public struct RuleBasedFormatter: Formatter {
    private static let filler = ["um", "uh", "erm"]

    public init() {}

    public func format(_ text: String, mode: Mode) async throws -> String {
        var out = text
        for word in Self.filler {
            // A negative lookbehind/lookahead over word characters and
            // hyphens, rather than \b, so the match doesn't fire inside
            // hyphenated interjections like "uh-huh" or "uh-oh" (a hyphen is
            // a non-word character, so plain \b would find a boundary right
            // at the hyphen).
            let escaped = NSRegularExpression.escapedPattern(for: word)
            let pattern = "(?<![\\w-])\(escaped)(?![\\w-])"
            out = out.replacingOccurrences(
                of: pattern, with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = out.rangeOfCharacter(from: .alphanumerics) != nil
        return hasContent ? out : text
    }
}
