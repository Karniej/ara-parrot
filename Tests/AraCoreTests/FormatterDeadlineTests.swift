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
}
