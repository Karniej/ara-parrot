import Foundation

/// Sanity-checks a formatter's output against its input.
///
/// Instruction-tuned models sometimes answer a transcript instead of rewriting
/// it — "what is the capital of France" comes back as "Paris". Since this app
/// types the result at the user's cursor, a wrong-shaped result is worse than
/// an unpolished one, so anything implausible is discarded in favour of raw.
///
/// This guard catches three distinct failure shapes, in order:
/// 1. **Answered instead of rewritten** — the output is far shorter than the
///    input relative to its word count (the lower ratio bound). This is the
///    "Paris" case.
/// 2. **Verbatim duplication** — the model echoes the whole input two or more
///    times instead of producing one rewrite. `max_tokens` doesn't catch this
///    because the duplicated text is often still well within budget.
/// 3. **Refusals** — the model declines to rewrite and returns a
///    conversational refusal ("I can't help with that") that would otherwise
///    pass the length checks with a plausible-looking ratio.
///
/// The upper length-ratio bound is a weak backstop against unbounded
/// runaway generation, not a strong signal on its own — email mode
/// legitimately expands terse speech into full, polite sentences, so the
/// bound is deliberately loose. Runaway generation itself is primarily
/// bounded by `max_tokens` at the call site, not by this guard.
///
/// Known limitation: this guard has no semantic understanding of the text.
/// An output that stays within the length ratio and isn't a verbatim
/// duplicate or a recognised refusal opener is accepted regardless of its
/// content — for example, a rewrite that faithfully reproduces the input's
/// length and shape but has a hostile or off-task instruction appended within
/// that budget would pass undetected. Catching that would require actually
/// understanding the text, which is out of scope for a pure, deterministic
/// function.
enum OutputGuard {
    /// Refusal openers, matched case-insensitively against the trimmed
    /// output's prefix. Matched only when the input itself doesn't also open
    /// with the same phrase, so a user dictating "I can't make Thursday"
    /// isn't mistaken for the model declining to help.
    private static let refusalOpeners = [
        "i can't", "i cannot", "i'm unable", "i am unable",
        "i'm sorry", "sorry, i", "i apologize", "i apologise", "as an ai",
    ]

    /// Folds typographic apostrophes onto the ASCII one.
    ///
    /// Every opener above is written with `'`, and a language model writing
    /// prose emits `’` (U+2019) at least as often — "I can’t help with that"
    /// matched nothing and was typed at the user's cursor as a rewrite. A
    /// refusal is one of the three shapes this guard exists to catch, so the
    /// comparison must not depend on which of two visually identical characters
    /// the model happened to pick. U+02BC is included because it is the other
    /// character Unicode calls an apostrophe; U+2018 is not, because a *left*
    /// quote in that position is an opening quotation mark, not a contraction.
    ///
    /// Applied to both sides of every comparison, so the "user genuinely
    /// dictated 'I can't ...'" exemption keeps working when the transcript and
    /// the rewrite disagree about the character.
    private static func foldApostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Counts non-overlapping occurrences of `needle` in `haystack`.
    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    static func isPlausible(input: String, output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let inWords = wordCount(input)
        let outWords = wordCount(trimmed)
        guard inWords > 0 else { return false }

        let inputLower = foldApostrophes(
            input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let outputLower = foldApostrophes(trimmed.lowercased())

        // Verbatim duplication: the model echoed the whole input two or more
        // times instead of rewriting it once. Only checked when the output
        // is longer than the input, so an unchanged echo of equal length
        // isn't caught.
        if outWords > inWords, !inputLower.isEmpty,
           occurrenceCount(of: inputLower, in: outputLower) > 1 {
            return false
        }

        // Refusal: the model declined instead of rewriting. Guarded so a
        // user who legitimately dictates "I can't ..." isn't rejected.
        for opener in refusalOpeners where outputLower.hasPrefix(opener) && !inputLower.hasPrefix(opener) {
            return false
        }

        // Short utterances legitimately change length a lot ("ok" -> "OK."),
        // so only the upper bound is meaningful there.
        if inWords < 4 { return outWords <= max(12, inWords * 4) }

        let ratio = Double(outWords) / Double(inWords)
        return ratio >= 0.4 && ratio <= 4.0
    }
}
