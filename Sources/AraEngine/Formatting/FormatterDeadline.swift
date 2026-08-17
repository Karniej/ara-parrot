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
/// **The fit is no longer what sets the budget, and this is why.** Timeouts
/// were seen on transcripts of 4 and 51 characters, which the fit puts at well
/// under a second, and again on 52, 111 and 143 characters in a session where
/// 200- and 279-character ones formatted in about a second each. That looked
/// like "another cause" until `overrunNote` measured one: 304 characters took
/// 4.6 s against a 4.5 s budget, where the fit predicts 1.6 s.
///
/// So the fit describes the median and the daemon lives with the tail. Real
/// generations scatter several times either side of this curve, which makes a
/// budget derived from it lose regularly — and losing means a silently worse
/// transcript. `perCharacterMs` is set generously against that spread rather
/// than fitted to the points above, which are kept because they are still the
/// only measured shape anyone has.
public enum FormatterDeadline {
    /// Milliseconds of budget per character of transcript.
    ///
    /// **Four times the measured 3.26 ms/char slope, and no longer fitted.**
    /// It was twice the slope, on the reasoning that a slower GPU has a
    /// steeper one. Then `overrunNote` answered the question this type could
    /// not: a 304-character transcript's generation ran 4.6 s against a 4.5 s
    /// budget — 0.1 s over. A near miss, not a stall, so the budget was the
    /// problem and the engine was not.
    ///
    /// The same number breaks the fit above. It predicts 1.6 s for 304
    /// characters; the truth was 4.6 s, and in the same session a
    /// 279-character transcript formatted in about a second. Near-identical
    /// lengths, four times apart. What this curve is fighting is **variance,
    /// not slope**, and a budget set near the median loses to the tail every
    /// time — which is exactly the reported symptom, cleanup that works until
    /// suddenly it does not.
    ///
    /// So this is deliberately generous rather than fitted. Being too generous
    /// costs a longer wait on an engine that is genuinely hung, bounded by
    /// `ceilingMs`; being too tight costs a silently worse transcript with no
    /// second chance. The second is the failure worth avoiding.
    ///
    /// One measurement is not a curve. `overrunNote` makes more of them free,
    /// and this should be re-set once there are several.
    public static let perCharacterMs: Double = 13

    /// The most the budget can reach, base included.
    ///
    /// The deadline exists so a hung engine cannot hold the cursor; without a
    /// ceiling, a long enough transcript would grow the budget until "abandon
    /// the stall" stopped meaning anything.
    ///
    /// Raised from 8 000 with `perCharacterMs`, and by less than the slope
    /// was: the ceiling is the one number a user actually waits out, so it is
    /// the one to keep tight. At the default base it now binds around 575
    /// characters — a long dictated paragraph — and everything past that gets
    /// ten seconds rather than a budget that keeps growing.
    public static let ceilingMs = 10_000

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
