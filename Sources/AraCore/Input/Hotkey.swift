import ArgumentParser
import CoreGraphics

/// A modifier key usable as the push-to-talk trigger.
///
/// `CGEventFlags` has one bit per modifier *class* — `.maskAlternate` is set for
/// both Option keys — so left/right variants are told apart by the keycode on the
/// `flagsChanged` event. Fn is the exception: it matches on the flag alone,
/// preserving the original behaviour on Apple's built-in keyboard.
public enum Hotkey: String, CaseIterable, Sendable, ExpressibleByArgument {
    case fn
    case leftOption = "left-option"
    case rightOption = "right-option"
    case leftCommand = "left-command"
    case rightCommand = "right-command"
    case leftControl = "left-control"
    case rightControl = "right-control"
    case rightShift = "right-shift"

    /// The modifier bit macOS sets while the key is held.
    var mask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftControl, .rightControl: return .maskControl
        case .rightShift: return .maskShift
        }
    }

    /// Keycode carried by the `flagsChanged` event, used to disambiguate the
    /// left and right variants. `nil` means match on `mask` alone.
    var keyCode: Int64? {
        switch self {
        case .fn: return nil
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .leftOption: return 58
        case .leftControl: return 59
        case .rightShift: return 60
        case .rightOption: return 61
        case .rightControl: return 62
        }
    }

    /// The `NX_DEVICE*KEYMASK` bit IOKit documents for this physical key.
    ///
    /// A hint, never a requirement — see `ModifierEdgeDetector`, which learns
    /// the bit a keyboard actually reports and uses this only to break a tie.
    /// The documented table is not reliable: on this machine the right control
    /// key reports `0x1` (`NX_DEVICELCTLKEYMASK`), not the `0x2000` listed here.
    var documentedDeviceBit: UInt64? {
        switch self {
        case .fn: return nil                    // Fn has no left/right variant.
        case .leftControl: return 0x0000_0001   // NX_DEVICELCTLKEYMASK
        case .rightShift: return 0x0000_0004    // NX_DEVICERSHIFTKEYMASK
        case .leftCommand: return 0x0000_0008   // NX_DEVICELCMDKEYMASK
        case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .leftOption: return 0x0000_0020    // NX_DEVICELALTKEYMASK
        case .rightOption: return 0x0000_0040   // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x0000_2000  // NX_DEVICERCTLKEYMASK
        }
    }

    /// Human-readable name for logs and the menu bar.
    public var label: String {
        switch self {
        case .fn: return "fn"
        case .leftOption: return "left ⌥"
        case .rightOption: return "right ⌥"
        case .leftCommand: return "left ⌘"
        case .rightCommand: return "right ⌘"
        case .leftControl: return "left ⌃"
        case .rightControl: return "right ⌃"
        case .rightShift: return "right ⇧"
        }
    }

    public static var valueNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}
