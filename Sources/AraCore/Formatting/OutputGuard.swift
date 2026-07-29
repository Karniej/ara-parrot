import Foundation

/// Sanity-checks a formatter's output against its input.
///
/// Instruction-tuned models sometimes answer a transcript instead of rewriting
/// it — "what is the capital of France" comes back as "Paris". Since this app
/// types the result at the user's cursor, a wrong-shaped result is worse than
/// an unpolished one, so anything implausible is discarded in favour of raw.
public enum OutputGuard {
    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func isPlausible(input: String, output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let inWords = wordCount(input)
        let outWords = wordCount(trimmed)
        guard inWords > 0 else { return false }

        // Short utterances legitimately change length a lot ("ok" -> "OK."),
        // so only the upper bound is meaningful there.
        if inWords < 4 { return outWords <= max(3, inWords * 3) }

        let ratio = Double(outWords) / Double(inWords)
        return ratio >= 0.4 && ratio <= 2.0
    }
}
