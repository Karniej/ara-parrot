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
/// second. Those have another cause — the leading candidate is contention with
/// a Whisper model still loading in the background — and scaling the deadline
/// neither fixes nor hides them: the chain still falls through to the rules
/// floor exactly as before. This type buys headroom for long dictation. It is
/// not a fix for a stalled engine.
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
}
