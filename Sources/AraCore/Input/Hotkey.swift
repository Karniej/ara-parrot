import ArgumentParser
import CoreGraphics

/// A modifier key usable as the push-to-talk trigger.
///
/// `CGEventFlags` has one bit per modifier *class* — `.maskAlternate` is set for
/// both Option keys — so left/right variants are told apart by the keycode on the
/// `flagsChanged` event. Fn is the exception: it matches on the flag alone,
/// preserving the original behaviour on Apple's built-in keyboard.
public enum Hotkey: String, CaseIterable, ExpressibleByArgument {
    case fn
    case leftOption = "left-option"
    case rightOption = "right-option"
    case leftCommand = "left-command"
    case rightCommand = "right-command"
    case leftControl = "left-control"
    case rightControl = "right-control"
    case rightShift = "right-shift"

    /// The modifier bit macOS sets while the key is held.
    public var mask: CGEventFlags {
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
    public var keyCode: Int64? {
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
