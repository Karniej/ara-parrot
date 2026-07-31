import Foundation
import Testing
@testable import AraCore

/// The Hub downloader calls its progress handler for every chunk of every
/// file, from whatever URLSession thread the transfer landed on. Turning each
/// of those into a hop to the main actor and a repaint of a pill whose text
/// can change at most a hundred times would be a repaint per byte, so the
/// stream is collapsed here — at the source, before the hop.
@Suite("Progress coalescer")
struct ProgressCoalescerTests {
    @Test("the first report always lands")
    func firstReport() {
        let coalescer = ProgressCoalescer()
        #expect(coalescer.step(0) == 0)
    }

    @Test("a change too small to see is not reported")
    func subPercentIsDropped() {
        let coalescer = ProgressCoalescer()
        #expect(coalescer.step(0.451) == 45)
        #expect(coalescer.step(0.452) == nil)
        #expect(coalescer.step(0.4599) == nil)
        #expect(coalescer.step(0.46) == 46)
    }

    /// Truncation, not rounding: 0.999 is not "100%", and a pill that says
    /// 100% while the download is still running is the specific lie this
    /// whole feature exists to avoid.
    @Test("percentages truncate, so 100 means finished")
    func truncation() {
        let coalescer = ProgressCoalescer()
        #expect(coalescer.step(0.999) == 99)
        #expect(coalescer.step(1.0) == 100)
    }

    /// `Progress.fractionCompleted` is a live object read from a callback on
    /// an arbitrary thread; two reads can arrive out of order. A percentage
    /// that goes backwards reads as a bug, so the last one reported stands.
    @Test("progress never goes backwards")
    func monotonic() {
        let coalescer = ProgressCoalescer()
        #expect(coalescer.step(0.60) == 60)
        #expect(coalescer.step(0.40) == nil)
        #expect(coalescer.step(0.61) == 61)
    }

    @Test("a fraction outside 0…1 is clamped rather than rendered")
    func clamping() {
        #expect(ProgressCoalescer().step(-0.5) == 0)
        #expect(ProgressCoalescer().step(2.0) == 100)
    }

    /// `Progress(totalUnitCount: 0).fractionCompleted` is NaN, and `Int(NaN)`
    /// traps. There is nothing to say about a download of nothing.
    @Test("a non-finite fraction reports nothing")
    func nonFinite() {
        let coalescer = ProgressCoalescer()
        #expect(coalescer.step(.nan) == nil)
        #expect(coalescer.step(.infinity) == nil)
        #expect(coalescer.step(0.5) == 50)
    }
}
