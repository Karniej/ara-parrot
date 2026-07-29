import Foundation

/// Turns a stream of `flagsChanged` events into press/release edges for one
/// modifier key.
///
/// ## The bug this exists to fix
///
/// `CGEventFlags` has one bit per modifier *class*: both shift keys set
/// `maskShift`. Deciding "is my key down?" from that bit alone is right only
/// while the sibling key is not also held. Hold left-shift, press right-shift
/// (recording starts), then release right-shift while left-shift is still
/// down: the `flagsChanged` for keycode 60 still carries `maskShift`, the
/// computed state matches the stored one, the release edge is swallowed, and
/// the daemon keeps recording until the user taps right-shift again. It
/// applies to every left/right pair.
///
/// ## The device bits, and why they are learned rather than assumed
///
/// The raw flags carry more than the class bit. The low bits are IOKit's
/// `NX_DEVICE*KEYMASK` family, one per *physical* key — captured on this
/// machine: right-shift `0x20104`, left-shift `0x20102`, left-command
/// `0x100108`, right-control `0x40101`. That decomposes as the class bit, plus
/// `0x100` (`NX_NONCOALSESCEDMASK`), plus one device bit: `0x4`
/// (`NX_DEVICERSHIFTKEYMASK`), `0x2` (`NX_DEVICELSHIFTKEYMASK`), `0x8`
/// (`NX_DEVICELCMDKEYMASK`) — and `0x1`, which is `NX_DEVICELCTLKEYMASK`, on
/// the key that is physically the *right* control.
///
/// That last one is the whole design constraint. A table lookup of "right
/// control means `NX_DEVICERCTLKEYMASK` (`0x2000`)" would have concluded that
/// the key was never down at all and broken the hotkey outright — turning a
/// stuck-recording bug into a dead key. These bits are keyboard- and
/// driver-dependent and not reliably portable, so this type does not trust the
/// table.
///
/// Instead it **learns**: at the press edge — the one moment the key is
/// unambiguously going down, because the class bit was clear and now is not —
/// it records whichever device bits appeared in that transition. Those bits are
/// then what distinguishes "still down" from "the sibling is down" for the rest
/// of the hold. The documented bit for the key is used only as a tie-breaker
/// when several bits appear at once, never as a requirement.
///
/// ## It cannot do worse than the code it replaces
///
/// If no device bits appear at the press edge — an external keyboard that does
/// not report them, a synthetic event, a remapper — nothing is learned and the
/// class bit decides, which is exactly the previous behaviour. The failure mode
/// is therefore "no better than before", never "worse than before". The one
/// case that stays wrong is a key already held when the process started, since
/// there is no observed transition to learn from; the next press of that key
/// re-learns it.
struct ModifierEdgeDetector {
    enum Edge { case pressed, released }

    /// The `NX_DEVICE*KEYMASK` bits, as a set. Everything outside this is
    /// excluded from learning: `0x100` (`NX_NONCOALSESCEDMASK`) toggles for
    /// reasons of its own and `0x80` is the stateless caps-lock bit, and
    /// learning either would attribute the sibling's events to our key.
    ///
    /// `0x1` left-control, `0x2` left-shift, `0x4` right-shift, `0x8`
    /// left-command, `0x10` right-command, `0x20` left-option, `0x40`
    /// right-option, `0x2000` right-control.
    static let deviceBits: UInt64 = 0x0000_207F

    private let classMask: UInt64
    private let keyCode: Int64?
    private let documentedDeviceBit: UInt64?

    private var isPressed = false
    private var lastFlags: UInt64 = 0
    /// Device bits observed at the most recent press edge. `0` means "this
    /// keyboard told us nothing", which reverts to class-bit-only behaviour.
    private var learnedDeviceBits: UInt64 = 0

    init(hotkey: Hotkey) {
        self.classMask = hotkey.mask.rawValue
        self.keyCode = hotkey.keyCode
        self.documentedDeviceBit = hotkey.documentedDeviceBit
    }

    /// Feed **every** `flagsChanged` event, in order, including events for keys
    /// that are not the hotkey.
    ///
    /// Events for other keys are not edges, but they are what keeps `lastFlags`
    /// honest: the sibling modifier's own press is usually the event
    /// immediately before ours, and without it the "which bits are new?"
    /// question at our press edge has no baseline to compare against.
    mutating func handle(keyCode code: Int64, flags: UInt64) -> Edge? {
        let previous = lastFlags
        lastFlags = flags

        // Left/right variants share a class bit, so the keycode on the event is
        // what tells them apart. Fn matches on the flag alone (keyCode == nil).
        if let expected = keyCode, code != expected { return nil }

        let classHeld = flags & classMask != 0
        var pressed = classHeld
        if classHeld {
            if !isPressed {
                learnedDeviceBits = Self.learn(previous: previous, flags: flags,
                                               documented: documentedDeviceBit)
            } else if learnedDeviceBits != 0 {
                // The class bit is set but our key's own bit is gone: this is
                // the release the class bit alone cannot see, because the
                // sibling key is holding the class bit up.
                pressed = flags & learnedDeviceBits != 0
            }
        }

        guard pressed != isPressed else { return nil }
        isPressed = pressed
        return pressed ? .pressed : .released
    }

    private static func learn(previous: UInt64, flags: UInt64,
                              documented: UInt64?) -> UInt64 {
        let appeared = flags & ~previous & deviceBits
        // Several bits at once means the baseline was stale (a key held since
        // before the first observed event). The documented bit is the only
        // evidence available to break the tie, and it is used only when it is
        // actually among the bits that appeared — never to override them.
        if let documented, appeared & documented != 0 { return appeared & documented }
        return appeared
    }
}
