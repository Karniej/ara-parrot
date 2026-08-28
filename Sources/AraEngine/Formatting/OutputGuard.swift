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

        // Person flip: the speaker's sentence, moved out of their mouth.
        if flipsPerson(input: inputLower, output: outputLower) { return false }

        // Translation: the speaker's sentence, in a language they did not use.
        if abandonsVocabulary(input: inputLower, output: outputLower) { return false }

        // Short utterances legitimately change length a lot ("ok" -> "OK."),
        // so only the upper bound is meaningful there.
        if inWords < 4 { return outWords <= max(12, inWords * 4) }

        let ratio = Double(outWords) / Double(inWords)
        return ratio >= minimumRatio(forWords: inWords) && ratio <= 4.0
    }

    /// How much of the transcript a rewrite must keep, by how long it was.
    ///
    /// A flat 0.4 was the rule, and it is the right number for a sentence:
    /// "um so I think maybe we should you know go" losing its filler is a
    /// legitimate 40% cut. It is the wrong number for a paragraph, and the
    /// difference is not academic — measured from a real dictation, 109 words
    /// in and 76 out, a ratio of 0.697. The rewrite had deleted the opening
    /// sentence, deleted the closing sentence, and pasted the opening back on
    /// the end. It sailed through this guard with 0.297 to spare and was typed
    /// at the user's cursor.
    ///
    /// The reason a flat floor fails is that filler does not scale. A speaker
    /// does not become three times as hesitant in a paragraph as in a
    /// sentence, so the *proportion* a faithful rewrite may drop should not
    /// grow with length — while a model's appetite for summarising very much
    /// does. So the floor rises: 0.4 up to 20 words, tightening to 0.8 by 100,
    /// and 0.8 above that.
    ///
    /// Whether the rewrite moved the sentence from the speaker to the listener.
    ///
    /// Reported from use: "am I running the newest version" came back as "are
    /// you running the newest version". None of the checks above see it — the
    /// length is right, nothing is duplicated, it is not a refusal, and it is
    /// not an answer. The words are even mostly the same. It is simply no
    /// longer the sentence the user spoke, and it gets typed at their cursor.
    ///
    /// ## Why this is here rather than in the prompt
    ///
    /// The prompt was tried first. A rule with a worked example fixed the
    /// exact shape in the example and nothing else: with "am i late" in the
    /// prompt, "am i running the newest version" was corrected and "should i
    /// cancel the meeting or move it" still came back as "should you".
    /// Measured on `scripts/cleanup-eval` at all three intensities. A
    /// deterministic check does not care which pronoun shape it meets, or what
    /// the model was told, or which model it is.
    ///
    /// ## Why the pair, and not either half
    ///
    /// It keys on first person *leaving* **and** second person *arriving*.
    /// Either alone is an ordinary edit:
    ///
    /// - "i think we should fix the login bug" → "We should fix the login
    ///   bug." drops the pronoun and adds no "you". That is tightening, and
    ///   `high` is licensed to do it.
    /// - "are you coming to dinner" is second person because the speaker made
    ///   it so; a rule reading the output alone would reject a correct
    ///   rewrite.
    ///
    /// Only the two together are the flip.
    private static func flipsPerson(input: String, output: String) -> Bool {
        let firstPersonIn = pronounCount(firstPerson, in: input)
        guard firstPersonIn > 0, pronounCount(firstPerson, in: output) == 0 else {
            return false
        }
        return pronounCount(secondPerson, in: output)
            > pronounCount(secondPerson, in: input)
    }

    /// Whether the rewrite kept so few of the speaker's own words that it is a
    /// translation rather than a tidy-up.
    ///
    /// Reported from use: dictating in Polish produced English. Measured on
    /// the shipped model, "czy ja uzywam najnowszej wersji" comes back as "Am
    /// I using the latest version?" while two longer Polish sentences survive
    /// — it is short utterances that get pulled into the language the
    /// instructions are written in.
    ///
    /// ## Why not ask the model
    ///
    /// Asking made it worse, and that is measured. Adding "write the rewrite
    /// in the same language the transcript is in; never translate" to the
    /// prompt turned one translated case into three and one of those into an
    /// *answer*: "no dobra teraz dyktuje ten sam prompt..." came back as "No,
    /// you're not doing well with this prompt. Let's try again." The line was
    /// reverted; this replaced it.
    ///
    /// ## Why word overlap
    ///
    /// It is the one thing that separates the two operations in any language
    /// pair, without knowing either language: a cleanup keeps the speaker's
    /// words and changes their punctuation and order; a translation keeps
    /// almost none of them. No language identification, no model, no table of
    /// languages to keep up to date.
    ///
    /// Diacritics are folded before comparing, because cleanup legitimately
    /// *restores* them — a transcriber that writes "wlasciwie" and a rewrite
    /// that writes "właściwie" are the same word, and an exact match would
    /// read a correction as a replacement.
    ///
    /// ## Which direction the overlap is measured in
    ///
    /// How much of the **input** survives, not how much of the output is
    /// borrowed. The other direction fails on expansion, and that was caught
    /// by an existing test rather than reasoned out: "reminder meeting 3pm" →
    /// "Reminder: the meeting is at 3pm this afternoon, please don't be late."
    /// keeps every word the speaker said and still shares only 23% of the
    /// output, because the rewrite is four times longer. Measured this way it
    /// scores 100%, which is the truth about it.
    ///
    /// The threshold sits far below any legitimate rewrite. A translation
    /// keeps 0–10% of the speaker's words (proper nouns and numbers survive);
    /// the harness's own cases measure 50–100%, including `high`
    /// restructuring, self-correction collapse, and filler removal.
    ///
    /// Short inputs are exempt. Three words carry too little signal, and an
    /// utterance that short is already covered by the length-ratio check.
    private static let vocabularyFloor = 0.25
    private static let shortestJudgeableInput = 4

    private static func abandonsVocabulary(input: String, output: String) -> Bool {
        let inputWords = Set(comparableWords(input))
        let outputWords = Set(comparableWords(output))
        guard inputWords.count >= shortestJudgeableInput else { return false }
        let survived = inputWords.filter { outputWords.contains($0) }.count
        return Double(survived) / Double(inputWords.count) < vocabularyFloor
    }

    /// Words with their diacritics folded away, so "właściwie" and
    /// "wlasciwie" compare equal.
    private static func comparableWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Matched as whole words, so "island" is not a first-person "i" and
    /// "your" is counted once rather than as a "you" inside a longer word.
    private static let firstPerson: Set<String> = ["i", "im", "ive", "id", "ill", "me", "my", "mine", "myself"]
    private static let secondPerson: Set<String> = ["you", "youre", "youve", "your", "yours", "yourself"]

    private static func pronounCount(_ set: Set<String>, in text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter })
            .reduce(into: 0) { total, word in
                if set.contains(String(word)) { total += 1 }
            }
    }

    /// A rejected rewrite costs polish, never words: the chain falls to the
    /// rules floor and the raw transcript is typed. That asymmetry is why the
    /// bound is set to catch the observed failure with margin rather than to
    /// sit just past it.
    static func minimumRatio(forWords words: Int) -> Double {
        let (shortEnough, longEnough) = (20.0, 100.0)
        let (loosest, tightest) = (0.4, 0.8)
        let count = Double(words)
        if count <= shortEnough { return loosest }
        if count >= longEnough { return tightest }
        let travelled = (count - shortEnough) / (longEnough - shortEnough)
        return loosest + travelled * (tightest - loosest)
    }
}
