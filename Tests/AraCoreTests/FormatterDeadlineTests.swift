import Foundation
import Testing
@testable import AraCore

@Suite("FormatterDeadline")
struct FormatterDeadlineTests {
    /// The default `Config.timeoutMs`, which is what the numbers below are
    /// stated against.
    let base = Duration.milliseconds(2500)

    // MARK: - The base is still the base

    @Test("an empty transcript gets exactly the configured base")
    func emptyIsBase() {
        #expect(FormatterDeadline.budget(base: base, characters: 0) == base)
    }

    @Test("a nonsensical character count degrades to the base")
    func negativeIsBase() {
        #expect(FormatterDeadline.budget(base: base, characters: -1) == base)
    }

    @Test("the configured base moves every budget with it")
    func baseIsTunable() {
        let tight = FormatterDeadline.budget(base: .milliseconds(500), characters: 200)
        let loose = FormatterDeadline.budget(base: .milliseconds(4000), characters: 200)
        #expect(loose - tight == .milliseconds(3500))
    }

    // MARK: - Growth

    @Test("the budget grows with the transcript")
    func growsMonotonically() {
        var previous = FormatterDeadline.budget(base: base, characters: 0)
        for characters in stride(from: 20, through: 600, by: 20) {
            let next = FormatterDeadline.budget(base: base, characters: characters)
            #expect(next >= previous)
            previous = next
        }
    }

    /// The requirement, stated against the measurement rather than against a
    /// round number: every length `MLXLengthBenchmark` covers must get a budget
    /// that clears its *worst* observed generation with margin to spare, so
    /// ordinary variance cannot push a real rewrite over the line. The maxima
    /// are the ones quoted in `FormatterDeadline`'s doc comment.
    @Test("every measured length clears its worst case with margin")
    func coversTheMeasuredWorstCase() {
        for (characters, measuredMax) in [(20, 710), (60, 857), (120, 1014),
                                          (200, 1426), (400, 2335)] {
            let budget = FormatterDeadline.budget(base: base, characters: characters)
            #expect(budget > .milliseconds(measuredMax * 2),
                    "\(characters) chars: \(budget) leaves too little over \(measuredMax) ms")
        }
    }

    /// Pinned rather than derived from the constants, so re-setting the curve
    /// has to come back through this file and the doc comment together.
    ///
    /// 13 ms/char on the default 2500 ms base. The old numbers were half
    /// these; see `perCharacterMs` for what these are worth, which is less than
    /// the last version of this comment claimed.
    @Test("the measured curve, at the default base")
    func pinnedCurve() {
        #expect(FormatterDeadline.budget(base: base, characters: 60)
                == .milliseconds(3280))
        #expect(FormatterDeadline.budget(base: base, characters: 200)
                == .milliseconds(5100))
        #expect(FormatterDeadline.budget(base: base, characters: 400)
                == .milliseconds(7700))
    }

    /// The one honest long measurement there is: a 280-character transcript
    /// whose rewrite genuinely *completed* in about 5.5 s. It has to fit, and
    /// it is the only reason `perCharacterMs` was not simply put back.
    ///
    /// The 304-character "4.6 s" sample this test used to cite was not a
    /// generation time at all — it was the moment cancellation took effect at
    /// a 4.5 s budget. See `FormatterDeadline`.
    @Test("a long rewrite that really did finish still fits")
    func measuredLongRewriteFits() {
        let budget = FormatterDeadline.budget(base: base, characters: 280)
        #expect(budget > .milliseconds(5_500))
        #expect(!FormatterDeadline.overran(elapsed: .milliseconds(5_500), base: base,
                                           characters: 280))
    }

    // MARK: - The ceiling

    @Test("a pathological transcript is capped")
    func ceiling() {
        let budget = FormatterDeadline.budget(base: base, characters: 100_000)
        #expect(budget == .milliseconds(FormatterDeadline.ceilingMs))
    }

    @Test("the cap is on the growth, never on the user's own value")
    func ceilingNeverLowersTheBase() {
        // Someone who writes `timeoutMs: 30000` has asked for a 30 s deadline
        // and gets one; the ceiling exists to bound what *we* add.
        let base = Duration.milliseconds(30_000)
        #expect(FormatterDeadline.budget(base: base, characters: 0) == base)
        #expect(FormatterDeadline.budget(base: base, characters: 100_000) == base)
    }

    @Test("the ceiling is reached, not approached, by a plausible transcript")
    func ceilingIsReachable() {
        // A minute of continuous dictation is around 900 characters; the cap
        // has to be somewhere a real user can get to, or it is decoration.
        #expect(FormatterDeadline.budget(base: base, characters: 2_000)
                == .milliseconds(FormatterDeadline.ceilingMs))
    }

    // MARK: - overran, the diagnosis the chain cannot make

    /// The assumed base has to be the shipped default, or every note this
    /// produces is measured against a budget nobody was given.
    @Test("the assumed base is the configured default")
    func assumedBaseMatchesTheDefault() {
        #expect(Duration.milliseconds(FormatterDeadline.defaultBaseMs) == base)
    }

    @Test("diagnostics follow tighter and looser configured timeouts")
    func diagnosticsUseConfiguredBase() {
        let elapsed = Duration.seconds(3)
        #expect(FormatterDeadline.overran(
            elapsed: elapsed, base: .milliseconds(500), characters: 52))
        #expect(!FormatterDeadline.overran(
            elapsed: elapsed, base: .milliseconds(4_000), characters: 52))
    }
    /// A generation inside its budget is the ordinary case and says nothing.
    /// The chain returned its rewrite; there is nothing to diagnose.
    @Test("a generation inside its budget has not overrun")
    func withinBudgetIsSilent() {
        // 52 characters — one of the field timeouts — gets 2500 + 676 ms.
        #expect(!FormatterDeadline.overran(elapsed: .milliseconds(1_000), base: base, characters: 52))
        #expect(!FormatterDeadline.overran(elapsed: .milliseconds(3_175), base: base, characters: 52))
    }

    @Test("a generation past its budget has overrun")
    func pastBudgetIsReported() {
        #expect(FormatterDeadline.overran(elapsed: .milliseconds(3_177), base: base, characters: 52))
        #expect(FormatterDeadline.overran(elapsed: .seconds(30), base: base, characters: 52))
    }

    /// The whole point: the same elapsed time is a different verdict depending
    /// on how much there was to rewrite. Four seconds on 52 characters is an
    /// overrun; on 279 characters — which formatted in about a second in the
    /// field — it is comfortably inside.
    @Test("the verdict scales with the transcript, like the budget does")
    func verdictScalesWithLength() {
        #expect(FormatterDeadline.overran(elapsed: .seconds(4), base: base, characters: 52))
        #expect(!FormatterDeadline.overran(elapsed: .seconds(4), base: base, characters: 279))
    }

    /// It must not go quiet on a stall just because the transcript was long:
    /// the ceiling bounds the budget, so past the ceiling everything overruns.
    @Test("a stall is reported at any transcript length")
    func stallIsAlwaysReported() {
        #expect(FormatterDeadline.overran(elapsed: .seconds(60), base: base, characters: 5_000))
    }

    // MARK: - what the overrun actually says

    @Test("a generation inside its budget produces no note")
    func noNoteWhenInsideBudget() {
        #expect(FormatterDeadline.overrunNote(elapsed: .seconds(1), base: base, characters: 52) == nil)
    }

    /// All three numbers, because none of them means anything alone: the
    /// elapsed time is not a fault without the budget, and the budget is not
    /// reproducible without the length it came from.
    @Test("the note carries the elapsed time, the overshoot, the budget and the length")
    func noteCarriesEveryNumber() {
        // 52 characters → 2500 + 676 = 3176 ms of budget.
        let note = FormatterDeadline.overrunNote(elapsed: .milliseconds(9_176), base: base,
                                                 characters: 52)
        #expect(note == "generation ran 9.2s, 6.0s past its 3.2s budget on 52 "
                + "characters — the transcript was delivered with rule-based "
                + "cleanup instead")
    }

    /// An overrun is not data loss and must not read like it. The user got
    /// their words; the chain fell through to the rules floor.
    @Test("the note says the transcript still arrived")
    func noteSaysTheTranscriptArrived() {
        let note = FormatterDeadline.overrunNote(elapsed: .seconds(30), base: base, characters: 100)
        #expect(note?.contains("delivered") == true)
    }

    // MARK: - the stall, kept apart from the overrun

    /// The ceiling has to sit past every rewrite ever seen to succeed, or a
    /// slow-but-working generation gets reported as a stall and the next person
    /// to read the log draws the same wrong conclusion again. The slowest
    /// honest success on record is **19.9 s**, measured in the field on 444
    /// characters — 0.1 s inside the twenty-second ceiling that was in place
    /// when it happened.
    @Test("the stall ceiling clears every observed success by a wide margin")
    func stallCeilingClearsRealWork() {
        #expect(FormatterDeadline.stallCeiling > .milliseconds(19_900) * 3 / 2)
        // And it still has to end: the engine takes one generation at a time,
        // so this is how long formatting stays offline after a stall.
        #expect(FormatterDeadline.stallCeiling <= .seconds(45))
    }

    /// The third outcome. Raising the budget for a runaway generation is the
    /// worst available response — the output is discarded by contract, so the
    /// extra wait buys a longer wait and nothing else. The wording has to make
    /// that unmistakable to whoever reads the log next.
    @Test("the runaway note blames the cap, not the budget")
    func runawayNoteBlamesTheCap() {
        let note = FormatterDeadline.runawayNote(
            elapsed: .milliseconds(19_900), base: base, characters: 444,
            tokenCap: 512)
        #expect(note.contains("512-token cap"))
        #expect(note.contains("running away"))
        #expect(note.contains("truncated"))
        #expect(note.contains("444 characters"))
        #expect(note.contains("delivered"))
        // It must not read as a near miss the curve could have covered.
        #expect(!note.contains("past its"))
    }

    /// It must be past the largest budget the curve can produce, or the two
    /// diagnostics overlap and a generation could be called stalled before it
    /// had even been given up on.
    @Test("the stall ceiling is past the largest possible budget")
    func stallCeilingIsPastTheCeiling() {
        #expect(FormatterDeadline.stallCeiling > .milliseconds(FormatterDeadline.ceilingMs))
    }

    /// The distinction this pair of notes exists to make. One says how much
    /// more budget would have been enough; the other says budget is not the
    /// lever. Conflating them is what cost a tuning decision.
    @Test("the stall note refuses to be read as a near miss")
    func stallNoteIsNotAnOverrun() {
        let note = FormatterDeadline.stallNote(
            elapsed: FormatterDeadline.stallCeiling, base: base, characters: 270)
        #expect(note.contains("did not finish"))
        #expect(note.contains("no budget would have caught it"))
        #expect(note.contains("270 characters"))
        #expect(note.contains("delivered"))
        // The overrun wording promises a cost; this one has none to report.
        #expect(!note.contains("past its"))
    }
}
