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
/// **The fit is not what sets the budget.** Timeouts were seen on transcripts
/// of 4 and 51 characters, which the fit puts at well under a second, and again
/// on 52, 111 and 143 characters in a session where 200- and 279-character ones
/// formatted in about a second each. What the field shows is not a steeper
/// slope but a much wider spread: in one session a 396-character transcript was
/// rewritten in 2.3 s and a 280-character one took 5.5 s, while 270- and
/// 374-character ones did not finish at all. Four transcripts of nearly the
/// same length, spanning more than a factor of two, with two of them off the
/// scale entirely.
///
/// So the fit describes the median and the daemon lives with the tail.
/// `perCharacterMs` is set generously against that spread rather than fitted to
/// the points above, which are kept because they are still the only measured
/// shape anyone has.
///
/// ## Do not tune these numbers from a timeout's elapsed time
///
/// This was done once and it was wrong, so the trap is written down. Before
/// `stallCeiling` existed, `FormatterChain.withDeadline` cancelled the work
/// task at the budget, and mlx-swift's token loop observes cancellation — so
/// the elapsed time `MLXFormatter` measured was *when cancellation took
/// effect*, never how long the generation needed. Every overrun in the field
/// duly reported 0.1–0.4 s past its budget, at every budget and every length,
/// because that is the cancellation latency and nothing else. Read as "the
/// budget is nearly right", it was used to double `perCharacterMs`, which
/// bought nothing and made the user wait 6–7 s for the same rules-based
/// fallback they previously got in 4 s.
///
/// The engine now runs on past the chain's budget so that the number is real —
/// see `stallCeiling`. Until several honest measurements exist, treat both
/// constants below as placeholders.
public enum FormatterDeadline {
    /// Milliseconds of budget per character of transcript.
    ///
    /// **Four times the measured 3.26 ms/char slope, and not fitted.** It is a
    /// guess, and it is written here as one: the field numbers that appeared to
    /// justify it were cancellation latency (see above), not generation time.
    ///
    /// It is left where it is rather than reverted because the one *honest*
    /// long measurement available argues for it — a 280-character transcript
    /// whose rewrite genuinely completed in about 5.5 s, which a 6.5 ms/char
    /// curve would have abandoned at 4.3 s. One sample is not a curve either.
    ///
    /// Being too generous costs a longer wait on an engine that is genuinely
    /// hung, bounded by `ceilingMs`; being too tight costs a silently worse
    /// transcript with no second chance. Re-set this from `overrunNote`'s
    /// output once there are several days of it.
    public static let perCharacterMs: Double = 13

    /// The most the budget can reach, base included.
    ///
    /// The deadline exists so a hung engine cannot hold the cursor; without a
    /// ceiling, a long enough transcript would grow the budget until "abandon
    /// the stall" stopped meaning anything.
    ///
    /// Raised from 8 000 with `perCharacterMs`, and by less than the slope
    /// was: the ceiling is the one number a user actually waits out, so it is
    /// the one to keep tight. At the default base it binds around 575
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

    // MARK: - Measuring what an overrun actually cost

    /// How long an engine may keep generating *after* the chain has given up on
    /// it, purely so that the cost of the overrun can be measured.
    ///
    /// Nothing waits on this. The chain abandoned the wait at `budget`, fell
    /// through to the rule-based floor and the user already has their words;
    /// the only thing still running is the generation, and the only thing it
    /// still produces is a number.
    ///
    /// That number is the one the daemon has never had. "Finished 1 s past the
    /// budget" and "was still going 20 s later" call for opposite responses —
    /// raise the curve, or stop blaming the curve — and they are
    /// indistinguishable from anywhere else in the process.
    ///
    /// **It is bounded because the engine is not free while it runs.**
    /// `MLXFormatter` allows one generation at a time, so a measurement that
    /// ran forever would take the formatting engine offline forever. Twenty
    /// seconds is far past every rewrite ever observed to succeed — the slowest
    /// was 5.5 s — so a generation that reaches it is stalled by definition,
    /// and no budget short of absurd would have caught it.
    public static let stallCeilingMs = 20_000

    public static var stallCeiling: Duration { .milliseconds(stallCeilingMs) }

    /// Whether a generation that took `elapsed` on `characters` of transcript
    /// ran past the budget it would have been given.
    ///
    /// ## Why an engine measures this at all
    ///
    /// `FormatterChain.withDeadline` abandons the *wait* at the budget, so the
    /// only elapsed time the chain can report on a timeout is the budget
    /// itself — the number it already knew. Whether the generation then
    /// finished at 3.5 s or at 30 s is the whole question, and nothing else in
    /// the process is in a position to ask it.
    ///
    /// An engine that keeps running after the chain has given up is the one
    /// place the answer exists — and it has to *actually* keep running, which
    /// is what `stallCeiling` and `MLXFormatter`'s unstructured generation task
    /// are for. A cancelled generation measures the deadline, not itself.
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

    /// The line for a generation that never finished at all, stopped at
    /// `stallCeiling`.
    ///
    /// Deliberately worded so it cannot be mistaken for `overrunNote`. That one
    /// reports a cost; this one reports the absence of one, and says outright
    /// that the curve is not the lever — because the previous version of this
    /// diagnostic quietly conflated the two and a whole tuning decision was
    /// made on the confusion.
    public static func stallNote(elapsed: Duration, base: Duration,
                                 characters: Int) -> String {
        String(
            format: "generation was still running %.0fs after it started on %d "
                + "characters (%.1fs budget) and was stopped — it did not "
                + "finish, so no budget would have caught it; the transcript "
                + "was delivered with rule-based cleanup instead",
            seconds(elapsed), characters,
            seconds(budget(base: base, characters: characters)))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (whole, attoseconds) = duration.components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
