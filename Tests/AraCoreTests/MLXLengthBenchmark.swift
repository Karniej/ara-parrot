import Foundation
import Testing
@testable import AraCore

/// How MLX formatting latency grows with the length of what was dictated — the
/// measurement behind `FormatterDeadline`'s coefficients, kept here so they can
/// be re-taken rather than trusted.
///
/// `MLXLatencyBenchmark` measures the *level* on six ~60-character transcripts;
/// this one measures the *slope*. They are separate suites because they answer
/// separate questions and the level one is pinned to the transcripts whose
/// correctness is tracked in docs/KNOWN-ISSUES.md — this suite's inputs are
/// chosen for their length, and nothing here asserts on the rewrite's content
/// beyond the tag-leak guarantee.
///
/// **Opt-in**: it loads a 0.9 GB model and runs fifteen real generations, so it
/// is inert unless `ARA_MLX_BENCH=1` is set. Run it with
///
/// ```
/// ARA_MLX_BENCH=1 swift test --filter MLXLength
/// ```
///
/// after `ara models download-formatter`. A release build is what the numbers
/// in `FormatterDeadline` were taken from (`swift test -c release`); a debug
/// build measures the same shape a little slower, since the compute is in
/// MLX's Metal kernels either way.
@Suite("MLXLength", .serialized)
struct MLXLengthBenchmark {
    /// Dictated speech at five lengths across the range a hotkey-held
    /// utterance actually covers: a few words, a sentence, a couple of
    /// sentences, a paragraph, and a long considered thought. Whisper's own
    /// output shape — lower case, no punctuation, filler words left in — since
    /// that is what the formatter is handed.
    ///
    /// Three per length rather than one, so a single transcript that happens
    /// to make the model verbose cannot set the slope on its own. The exact
    /// character counts are printed by the run; they are within a few
    /// characters of the nominal bucket.
    static let corpus: [(nominal: Int, transcripts: [String])] = [
        (20, [
            "lets ship it tomorrow",
            "can you check the logs",
            "remind me to call ben",
        ]),
        (60, [
            "hey can you send me the notes from yesterdays standup please",
            "i think we should wait until after the launch to change it",
            "the parser is failing on the new format so the tests are red",
        ]),
        (120, [
            "so the plan for this week is to finish the parser refactor and "
                + "then write the integration tests and ship on thursday",
            "i spoke to sarah about the pricing page and she thinks we should "
                + "hold it until the launch is done and the numbers settle",
            "the build is green again but i had to pin the toolchain version "
                + "because the new one breaks the metal shader compilation",
        ]),
        (200, [
            "ok so here is where we landed on the migration we are going to "
                + "run both schemas side by side for a week and then cut over "
                + "on the weekend when traffic is low and if anything breaks "
                + "we can roll back in about ten minutes",
            "i went through the crash reports this morning and almost all of "
                + "them are the same audio thread issue we saw last month so i "
                + "think the fix is to move the buffer handling off the "
                + "realtime callback entirely rather than adding another lock",
            "the thing that worries me about shipping on friday is not the "
                + "tests it is that nobody is around over the weekend to watch "
                + "the rollout so if something goes wrong in production we "
                + "find out on monday morning from a customer email",
        ]),
        (400, [
            "right so the summary of the whole investigation is that the "
                + "latency we were chasing was never in the model at all it "
                + "was in the way we were loading it every single request "
                + "paid the pipeline compilation cost because the container "
                + "was being rebuilt each time and once we hoisted that up "
                + "into the warm up path the median dropped by about three "
                + "quarters and the tail went away completely which also "
                + "explains why the first request after a restart always "
                + "looked so much worse than the rest of them did",
            "so my proposal for the next quarter is that we stop adding "
                + "features for about six weeks and spend that time on the "
                + "things that keep breaking which is mostly the sync layer "
                + "and the migration tooling because every time we ship "
                + "something new on top of them we lose two or three days to "
                + "firefighting and that is time we never planned for and it "
                + "makes every estimate we give wrong by a wide margin and "
                + "eventually people stop believing the estimates at all "
                + "which is the part that actually costs us",
            "the customer call this morning was useful they are not actually "
                + "asking for more integrations what they want is for the "
                + "existing ones to stop silently dropping records and they "
                + "were pretty clear that they would rather have five "
                + "connectors that never lose data than twenty that mostly "
                + "work so i think that settles the roadmap argument we have "
                + "been having and it also means the reliability work we "
                + "keep deferring is the feature work now not a tax on it",
        ]),
    ]

    @Test("formatting latency against transcript length")
    func measure() async throws {
        guard ProcessInfo.processInfo.environment["ARA_MLX_BENCH"] == "1" else { return }
        guard #available(macOS 15.4, *) else { return }
        try #require(MLXModel.isPresent,
                     "run `\(MLXModel.downloadCommand)` first")

        let mode = ModeRegistry.defaultMode
        let formatter = MLXFormatter()
        try await formatter.warmUp()

        print("chars  out  ms")
        var points: [(chars: Double, ms: Double)] = []
        for bucket in Self.corpus {
            var bucketMs: [Double] = []
            for transcript in bucket.transcripts {
                let start = ContinuousClock.now
                let out = try await formatter.format(transcript, mode: mode)
                let elapsed = Self.ms(ContinuousClock.now - start)
                bucketMs.append(elapsed)
                points.append((Double(transcript.count), elapsed))
                print(String(format: "%5d %4d %6.0f", transcript.count,
                             out.count, elapsed))
                // The one assertion, same as the level benchmark's: a
                // `<transcript>` tag typed at the user's cursor is the failure
                // the prompt's closing sentence exists to prevent.
                #expect(!out.contains("<transcript>"))
                #expect(!out.contains("<think>"))
            }
            let sorted = bucketMs.sorted()
            print(String(format: "  ~%d chars: median %.0f ms, max %.0f ms",
                         bucket.nominal, sorted[sorted.count / 2], sorted.last!))
        }

        // Ordinary least squares through every point, which is the fit
        // `FormatterDeadline` quotes. Printed rather than asserted: this suite
        // is an instrument, and a machine slower than the one the constants
        // were taken from should report a different slope, not fail.
        let n = Double(points.count)
        let meanX = points.map(\.chars).reduce(0, +) / n
        let meanY = points.map(\.ms).reduce(0, +) / n
        let covariance = points.map { ($0.chars - meanX) * ($0.ms - meanY) }.reduce(0, +)
        let variance = points.map { ($0.chars - meanX) * ($0.chars - meanX) }.reduce(0, +)
        let slope = covariance / variance
        let intercept = meanY - slope * meanX
        print(String(format: "fit: %.0f ms + %.2f ms/char", intercept, slope))

        // The worst case each point sat above the fit, which is what a
        // deadline has to cover rather than the fit itself.
        let residual = points.map { $0.ms - (intercept + slope * $0.chars) }.max() ?? 0
        print(String(format: "largest positive residual: %.0f ms", residual))
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }
}
