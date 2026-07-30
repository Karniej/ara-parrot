import CoreGraphics
import Testing
@testable import AraCore

/// Raw `CGEventFlags` values captured from a real keyboard on the development
/// machine with `parrot run --debug-hotkey`, reused here so the tests exercise
/// the bit patterns macOS actually emits rather than a reconstruction of them.
private enum Flags {
    static let none: UInt64 = 0x0000_0000
    /// `NX_NONCOALSESCEDMASK` alone — what a release back to no modifiers looks like.
    static let idle: UInt64 = 0x0000_0100

    static let leftShift: UInt64 = 0x0002_0102   // maskShift | 0x100 | 0x2
    static let rightShift: UInt64 = 0x0002_0104  // maskShift | 0x100 | 0x4
    static let bothShifts: UInt64 = 0x0002_0106
    static let leftCommand: UInt64 = 0x0010_0108
    static let rightCommand: UInt64 = 0x0010_0110
    static let bothCommands: UInt64 = 0x0010_0118
    /// The anomaly: the physically-right control key reports the device bit
    /// IOKit documents for the *left* one.
    static let rightControl: UInt64 = 0x0004_0101
    /// A keyboard that reports no device bits at all.
    static let shiftNoDeviceBits: UInt64 = 0x0002_0100
}

private enum Keys {
    static let leftShift: Int64 = 56
    static let rightShift: Int64 = 60
    static let leftCommand: Int64 = 55
    static let rightCommand: Int64 = 54
    static let rightControl: Int64 = 62
}

@Suite("ModifierEdgeDetector")
struct ModifierEdgeDetectorTests {
    @Test("a plain press and release")
    func simplePressRelease() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.rightShift) == .pressed)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.idle) == .released)
    }

    @Test("another key's modifier is ignored")
    func otherKeyIgnored() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.leftShift) == nil)
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.idle) == nil)
    }

    /// The finding. Left-shift held, right-shift pressed and then released:
    /// the release event still carries `maskShift`, because left-shift is
    /// holding it up. Before the device-bit work this returned `nil` and the
    /// daemon recorded until the user tapped right-shift again.
    @Test("release is seen while the sibling key is still held")
    func releaseWithSiblingHeld() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.leftShift) == nil)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.bothShifts) == .pressed)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.leftShift) == .released)
        // And the still-held sibling going away afterwards is not a second edge.
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.idle) == nil)
    }

    @Test("the sibling arriving mid-hold is not a release")
    func siblingPressedDuringHold() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.rightShift) == .pressed)
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.bothShifts) == nil)
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.rightShift) == nil)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.idle) == .released)
    }

    @Test("the sibling released first leaves our key held")
    func siblingReleasedFirst() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.rightShift) == .pressed)
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.bothShifts) == nil)
        // Left released: our bit is still there, so we are still recording.
        #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.rightShift) == nil)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.idle) == .released)
    }

    @Test("the same holds for the command pair")
    func commandPair() {
        var d = ModifierEdgeDetector(hotkey: .rightCommand)
        #expect(d.handle(keyCode: Keys.leftCommand, flags: Flags.leftCommand) == nil)
        #expect(d.handle(keyCode: Keys.rightCommand, flags: Flags.bothCommands) == .pressed)
        #expect(d.handle(keyCode: Keys.rightCommand, flags: Flags.leftCommand) == .released)
    }

    /// The reason the device bit is learned instead of looked up. This key
    /// reports `NX_DEVICELCTLKEYMASK`; a table lookup would have demanded
    /// `NX_DEVICERCTLKEYMASK` and concluded the key was never pressed at all.
    @Test("a key reporting the wrong documented device bit still works")
    func rightControlReportsLeftBit() {
        var d = ModifierEdgeDetector(hotkey: .rightControl)
        #expect(d.handle(keyCode: Keys.rightControl, flags: Flags.rightControl) == .pressed)
        #expect(d.handle(keyCode: Keys.rightControl, flags: Flags.idle) == .released)
    }

    /// The case that separates learning the bit from looking it up, and the
    /// reason the implementation learns.
    ///
    /// Hypothetical hardware, but only in its second half: the right control key
    /// reporting `NX_DEVICELCTLKEYMASK` is a real capture from this machine, and
    /// once the table is known to be wrong about one key of a pair there is no
    /// principled reason to trust it about the other. So: our key reports `0x1`,
    /// while the sibling reports the `0x2000` the table assigns to *us*.
    ///
    /// A lookup-based detector consults `0x2000`, sees the sibling still holding
    /// it, and concludes our key is down — recording never stops. Learning takes
    /// the bit that appeared when the key actually went down and sees it leave.
    @Test("the sibling holding our documented bit does not swallow the release")
    func siblingHoldsOurDocumentedBit() {
        let siblingHeld: UInt64 = 0x0004_2100   // maskControl | 0x100 | 0x2000
        let bothHeld: UInt64 = 0x0004_2101      // + our real bit, 0x1
        var d = ModifierEdgeDetector(hotkey: .rightControl)
        #expect(d.handle(keyCode: 59, flags: siblingHeld) == nil)
        #expect(d.handle(keyCode: Keys.rightControl, flags: bothHeld) == .pressed)
        #expect(d.handle(keyCode: Keys.rightControl, flags: siblingHeld) == .released)
    }

    /// The safety property: where the device bits are absent the detector must
    /// be no worse than the class-bit-only code it replaced.
    @Test("a keyboard reporting no device bits degrades to class-bit behaviour")
    func noDeviceBits() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.shiftNoDeviceBits) == .pressed)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.idle) == .released)
    }

    @Test("fn matches on the class flag alone, whatever the keycode")
    func fnMatchesOnFlag() {
        let fnDown: UInt64 = 0x0080_0100  // maskSecondaryFn | 0x100
        var d = ModifierEdgeDetector(hotkey: .fn)
        #expect(d.handle(keyCode: 63, flags: fnDown) == .pressed)
        #expect(d.handle(keyCode: 63, flags: Flags.idle) == .released)
    }

    /// Fn is the default hotkey and the only one with no keycode gate, so every
    /// event in the stream is a candidate edge for it — and it has no left/right
    /// sibling, so there is nothing for a device bit to disambiguate. Learning
    /// for it therefore attributes some *other* key's bit to Fn, and that key
    /// going up mid-hold fabricates a release the user never asked for: one
    /// truncated utterance on the default hotkey.
    ///
    /// The exact sequence, measured against the unguarded implementation: the Fn
    /// press learned `0x2` from the already-held shift, and the shift release
    /// returned `.released` with Fn still physically down.
    ///
    /// Mutation: remove the `keyCode == nil` guard from `handle` and the second
    /// expectation fails with `.released`.
    @Test("a foreign modifier going up mid-hold does not fabricate an fn release")
    func fnDoesNotLearnAForeignDeviceBit() {
        let fnWithShiftHeld: UInt64 = 0x0082_0102   // maskSecondaryFn | maskShift | 0x100 | 0x2
        let shiftReleasedFnDown: UInt64 = 0x0080_0100
        var d = ModifierEdgeDetector(hotkey: .fn)
        // Fn goes down while shift is already physically held.
        #expect(d.handle(keyCode: 63, flags: fnWithShiftHeld) == .pressed)
        // Shift comes up. Fn is still down, so this is not an edge at all.
        #expect(d.handle(keyCode: Keys.leftShift, flags: shiftReleasedFnDown) == nil)
        // And the real release still lands.
        #expect(d.handle(keyCode: 63, flags: Flags.idle) == .released)
    }

    /// The same shape with the modifier arriving *after* Fn rather than before,
    /// which the diff would attribute to nothing but which must still be inert.
    @Test("a foreign modifier pressed and released during an fn hold is inert")
    func fnIgnoresForeignModifierChurn() {
        let fnDown: UInt64 = 0x0080_0100
        let fnPlusShift: UInt64 = 0x0082_0102
        var d = ModifierEdgeDetector(hotkey: .fn)
        #expect(d.handle(keyCode: 63, flags: fnDown) == .pressed)
        #expect(d.handle(keyCode: Keys.leftShift, flags: fnPlusShift) == nil)
        #expect(d.handle(keyCode: Keys.leftShift, flags: fnDown) == nil)
        #expect(d.handle(keyCode: 63, flags: Flags.idle) == .released)
    }

    @Test("repeated presses re-learn the device bit each time")
    func repeatedHolds() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        for _ in 0..<3 {
            #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.leftShift) == nil)
            #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.bothShifts) == .pressed)
            #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.leftShift) == .released)
            #expect(d.handle(keyCode: Keys.leftShift, flags: Flags.none) == nil)
        }
    }

    /// The documented limitation, pinned so it is a known state rather than a
    /// surprise: a sibling held since before the first observed event gives the
    /// press edge no baseline, so both bits look new. The documented bit breaks
    /// the tie and the release is still seen.
    @Test("a stale baseline is resolved by the documented device bit")
    func staleBaselineTieBreak() {
        var d = ModifierEdgeDetector(hotkey: .rightShift)
        // First event ever: both shifts already down.
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.bothShifts) == .pressed)
        #expect(d.handle(keyCode: Keys.rightShift, flags: Flags.leftShift) == .released)
    }

}

/// The tap subscribes to the one event type the detector consumes.
/// `flagsChanged` is where modifier keycodes arrive; keyDown/keyUp would hand
/// this process the content of every keystroke typed system-wide, for nothing.
@Suite("HotkeyMonitor event mask")
struct HotkeyMonitorMaskTests {
    @Test("the tap listens to flagsChanged only")
    func maskIsFlagsChangedOnly() {
        #expect(HotkeyMonitor.eventMask == CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    }
}

