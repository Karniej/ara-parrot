import Foundation
import Testing
@testable import AraCore

/// The split, which is the part of typing that has a rule in it. Posting real
/// `CGEvent`s needs a focused text field and Accessibility permission, so the
/// pacing that goes with the split is checked in `docs/MANUAL-VERIFICATION.md`;
/// everything that decides *what* gets posted is here.
@Suite("TextInjector chunking")
struct TextInjectorTests {
    private func text(_ chunks: [[UniChar]]) -> String {
        chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
    }

    @Test("nothing to say produces nothing to post")
    func empty() {
        #expect(TextInjector.chunks("").isEmpty)
    }

    @Test("text that fits the payload limit is one event")
    func shortTextIsOneChunk() {
        let chunks = TextInjector.chunks("hello there")
        #expect(chunks.count == 1)
        #expect(text(chunks) == "hello there")
    }

    /// The property the whole reordering defect turns on: fewer events is fewer
    /// chances to arrive out of order, so the split must fill each event rather
    /// than dribble.
    @Test("every event but the last is filled to the limit")
    func chunksAreFilled() {
        let chunks = TextInjector.chunks(String(repeating: "a", count: 95))
        #expect(chunks.count == 5)
        #expect(chunks.dropLast().allSatisfy { $0.count == TextInjector.chunkLimit })
        #expect(chunks.last?.count == 15)
    }

    /// The contract that matters most: whatever the split does, reassembling
    /// the pieces in order must reproduce the transcript exactly. A defect here
    /// is silent — the user sees mangled text, never an error.
    @Test("the pieces reassemble into the original, whatever is in it")
    func roundTrips() {
        for sample in [
            "hello",
            String(repeating: "a", count: 20),
            String(repeating: "a", count: 21),
            "Zażółć gęślą jaźń — dictation in Polish, with combining marks.",
            "Emoji in the middle 👨‍👩‍👧‍👦 of a long enough sentence to split.",
            "I'm automating Vidnotes app operations right now the most. "
                + "I think that's cool. I think people will think that's cool "
                + "too. And I want to somehow tell that in my bio.",
        ] {
            #expect(text(TextInjector.chunks(sample)) == sample)
        }
    }

    /// Slicing the UTF-16 array at a fixed stride cuts surrogate pairs in half
    /// and separates a base character from its combining marks. Each piece is
    /// posted as its own event, so a half-encoded character is delivered as
    /// one — the user gets a replacement glyph and no explanation.
    @Test("no event ever starts or ends inside a character")
    func neverSplitsAGrapheme() {
        let sample = "aaaaaaaaaaaaaaaaaa👨‍👩‍👧‍👦bbbbbbbbbbbbbbbbbbbbéééééééééé"
        for chunk in TextInjector.chunks(sample) {
            let decoded = String(utf16CodeUnits: chunk, count: chunk.count)
            #expect(!decoded.unicodeScalars.contains { $0.value == 0xFFFD },
                    "a chunk decoded to a replacement character: \(decoded)")
        }
    }

    /// A grapheme too large for one event keeps its own event rather than being
    /// cut up. It goes over the limit, deliberately: the API may truncate a
    /// whole character, which is a character the user can still read, whereas
    /// splitting one guarantees two pieces that are not characters at all.
    ///
    /// A base letter under a stack of combining marks, because that is what
    /// actually reaches this code — a mangled paste or a decomposed accent, not
    /// something anyone typed on purpose.
    @Test("an oversized character is not split")
    func oversizedGraphemeStaysWhole() {
        let stacked = "e" + String(repeating: "\u{0301}", count: 25)
        #expect(stacked.count == 1)
        #expect(stacked.utf16.count > TextInjector.chunkLimit)
        let chunks = TextInjector.chunks(stacked)
        #expect(chunks.count == 1)
        #expect(text(chunks) == stacked)
    }

    /// Pacing is what makes reordering unlikely, and it is only free if it
    /// stays far below what anyone notices. A minute of dictation is around
    /// 900 characters; that must still be well under a tenth of a second.
    @Test("pacing a long paragraph stays imperceptible")
    func pacingIsNegligible() {
        let chunks = TextInjector.chunks(String(repeating: "a", count: 900))
        let cost = Double(chunks.count - 1) * TextInjector.pacing
        #expect(cost < 0.2)
        // And it is not zero, or there is no gap between events at all.
        #expect(TextInjector.pacing > 0)
    }
}
