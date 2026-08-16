import Foundation

/// How long one formatter gets, given how much there is to format.
///
/// Generation time grows with the length of the rewrite, so a fixed budget is a
/// budget that shrinks as the user dictates more. Measured with
/// `MLXLengthBenchmark` (15 real generations, Qwen2.5-1.5B-Instruct-4bit,
/// release build), ordinary least squares through every point:
///
/// ```
///  ~20 chars: median  680 ms
///  ~60 chars: median  857 ms
/// ~120 chars: median 1004 ms
/// ~200 chars: median 1345 ms
/// ~400 chars: median 2273 ms
/// fit: 628 ms + 3.26 ms/char, largest positive residual 106 ms
/// ```
///
/// So the default 2500 ms base covers a warm machine out to roughly 500
/// characters and no further — a dictated paragraph is where it runs out, which
/// is the wrong place for cleanup to silently stop happening.
///
/// **What this does not explain.** Formatter timeouts have been observed on
/// transcripts of 4 and 51 characters, which the fit above puts at well under a
/// second — and again in the field on 52, 111 and 143 characters in one
/// session, while 200- and 279-character transcripts in the same session
/// formatted in about a second each. Those have another cause, and scaling the
/// deadline neither fixes nor hides them: the chain still falls through to the
/// rules floor exactly as before. This type buys headroom for long dictation.
/// It is not a fix for a stalled engine.
///
/// `overran` exists to find out which it is — see its doc.
public enum FormatterDeadline {
    /// Milliseconds of budget per character of transcript.
    ///
    /// Twice the measured 3.26 ms/char slope. The doubling is for machine
    /// variance — a slower GPU has a steeper slope, not merely a higher
    /// intercept — and the base absorbs the intercept and the residual on top
    /// of that. Cutting it to the raw slope would put a slower Mac's long
    /// dictation back on the rules floor, which is the failure being fixed.
    public static let perCharacterMs: Double = 6.5

    /// The most the budget can reach, base included.
    ///
    /// The deadline exists so a hung engine cannot hold the cursor; without a
    /// ceiling, a long enough transcript would grow the budget until "abandon
    /// the stall" stopped meaning anything. At the default base this is reached
    /// around 850 characters — past where generation actually finishes, so it
    /// binds on hangs and not on real work.
    public static let ceilingMs = 8_000

    /// `base` plus the per-character allowance, clamped to `ceilingMs`.
    ///
    /// Never returns less than `base`: a configured timeout is a floor the
    /// caller chose, and a ceiling below it is a misconfiguration to be
    /// honoured rather than silently tightened.
    public static func budget(base: Duration, characters: Int) -> Duration {
        guard characters > 0 else { return base }
        let grown = base + .milliseconds(Int((Double(characters) * perCharacterMs).rounded()))
        let ceiling = Duration.milliseconds(ceilingMs)
        return grown > ceiling ? max(base, ceiling) : grown
    }

    /// `Config.timeoutMs`'s default.
    public static let defaultBaseMs = 2_500

    /// Whether a generation that took `elapsed` on `characters` of transcript
    /// ran past the budget it would have been given.
    ///
    /// ## Why an engine measures this at all
    ///
    /// `FormatterChain.withDeadline` abandons the *wait*, not the work, so the
    /// only elapsed time the chain can report on a timeout is the budget
    /// itself — the number it already knew. Whether the generation then
    /// finished at 3.5 s or at 30 s is the whole question, and nothing was
    /// asking it. That is why the note above has to say the short-transcript
    /// timeouts have "another cause" without naming one.
    ///
    /// An engine that keeps running after the chain has given up is the one
    /// place the answer exists. Just past the budget means the budget is too
    /// tight and `perCharacterMs` is the lever; many seconds past it means the
    /// engine stalled and no budget would have helped.
    ///
    /// `base` is the configured per-attempt timeout. Diagnostics must use the
    /// same value as the chain or they can report a successful generation as a
    /// fallback, or miss a real fallback under a tighter setting.
    public static func overran(elapsed: Duration, base: Duration,
                               characters: Int) -> Bool {
        elapsed > budget(base: base, characters: characters)
    }

    /// The line an engine writes when its generation outlived the chain's
    /// patience, or `nil` when it did not and there is nothing to say.
    ///
    /// Both numbers are here because neither means anything alone. "5.9s" is
    /// not a fault on a long transcript and is a serious one on a short
    /// transcript, and the budget is what makes the difference legible without
    /// the reader having to know `perCharacterMs`. The character count is the
    /// third number because it is the one that would let someone reproduce it.
    ///
    /// It ends by saying the transcript was still delivered. An overrun reads
    /// like data loss otherwise, and it is not: `FormatterChain` fell through
    /// to the rules floor and the user got their words, just less tidy.
    public static func overrunNote(elapsed: Duration, base: Duration,
                                   characters: Int) -> String? {
        let budget = budget(base: base, characters: characters)
        guard elapsed > budget else { return nil }
        return String(
            format: "generation ran %.1fs, %.1fs past its %.1fs budget on %d "
                + "characters — the transcript was delivered with rule-based "
                + "cleanup instead",
            seconds(elapsed), seconds(elapsed - budget), seconds(budget),
            characters)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (whole, attoseconds) = duration.components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
