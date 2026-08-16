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

    /// Pinned rather than derived from the constants, so re-measuring the
    /// model has to come back through this file and the doc comment together.
    @Test("the measured curve, at the default base")
    func pinnedCurve() {
        #expect(FormatterDeadline.budget(base: base, characters: 60)
                == .milliseconds(2890))
        #expect(FormatterDeadline.budget(base: base, characters: 200)
                == .milliseconds(3800))
        #expect(FormatterDeadline.budget(base: base, characters: 400)
                == .milliseconds(5100))
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

    /// A generation inside its budget is the ordinary case and says nothing.
    /// The chain returned its rewrite; there is nothing to diagnose.
    @Test("a generation inside its budget has not overrun")
    func withinBudgetIsSilent() {
        // 52 characters — one of the field timeouts — gets 2500 + 338 ms.
        #expect(!FormatterDeadline.overran(elapsed: .milliseconds(1_000), characters: 52))
        #expect(!FormatterDeadline.overran(elapsed: .milliseconds(2_837), characters: 52))
    }

    @Test("a generation past its budget has overrun")
    func pastBudgetIsReported() {
        #expect(FormatterDeadline.overran(elapsed: .milliseconds(2_839), characters: 52))
        #expect(FormatterDeadline.overran(elapsed: .seconds(30), characters: 52))
    }

    /// The whole point: the same elapsed time is a different verdict depending
    /// on how much there was to rewrite. Three seconds on 52 characters is an
    /// overrun; on 279 characters — which formatted in about a second in the
    /// field — it is comfortably inside.
    @Test("the verdict scales with the transcript, like the budget does")
    func verdictScalesWithLength() {
        #expect(FormatterDeadline.overran(elapsed: .seconds(3), characters: 52))
        #expect(!FormatterDeadline.overran(elapsed: .seconds(3), characters: 279))
    }

    /// It must not go quiet on a stall just because the transcript was long:
    /// the ceiling bounds the budget, so past the ceiling everything overruns.
    @Test("a stall is reported at any transcript length")
    func stallIsAlwaysReported() {
        #expect(FormatterDeadline.overran(elapsed: .seconds(60), characters: 5_000))
    }

    // MARK: - what the overrun actually says

    @Test("a generation inside its budget produces no note")
    func noNoteWhenInsideBudget() {
        #expect(FormatterDeadline.overrunNote(elapsed: .seconds(1), characters: 52) == nil)
    }

    /// All three numbers, because none of them means anything alone: the
    /// elapsed time is not a fault without the budget, and the budget is not
    /// reproducible without the length it came from.
    @Test("the note carries the elapsed time, the overshoot, the budget and the length")
    func noteCarriesEveryNumber() {
        // 52 characters → 2500 + 338 = 2838 ms of budget.
        let note = FormatterDeadline.overrunNote(elapsed: .milliseconds(8_838),
                                                 characters: 52)
        #expect(note == "generation ran 8.8s, 6.0s past its 2.8s budget on 52 "
                + "characters — the transcript was delivered with rule-based "
                + "cleanup instead")
    }

    /// An overrun is not data loss and must not read like it. The user got
    /// their words; the chain fell through to the rules floor.
    @Test("the note says the transcript still arrived")
    func noteSaysTheTranscriptArrived() {
        let note = FormatterDeadline.overrunNote(elapsed: .seconds(30), characters: 100)
        #expect(note?.contains("delivered") == true)
    }
}
