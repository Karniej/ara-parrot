import SwiftUI
import UIKit

/// Ara's palette, adaptive: dark is the VidNotes standard (pure black, one
/// amber), light is warm paper with the same amber deepened to ember so
/// tinted text keeps contrast. Every color in the app and the keyboard comes
/// from here — a hardcoded color anywhere else is a review defect. The one
/// exception: black text on an accent-filled control, which reads in both
/// modes because the fill itself does not adapt much.
enum Theme {
    /// Ara amber (dark) / ember (light). Fills keep the warm identity; as a
    /// text/icon tint the light variant is dark enough to pass contrast on
    /// paper.
    static let accent = adaptive(
        dark: UIColor(red: 1, green: 190 / 255, blue: 118 / 255, alpha: 1),
        light: UIColor(red: 193 / 255, green: 120 / 255, blue: 40 / 255, alpha: 1))
    /// Accent for filled controls (buttons, switches): stays amber in both
    /// modes so the brand element is constant; pair with black text.
    static let accentFill = Color(red: 1, green: 190 / 255, blue: 118 / 255)
    static let background = adaptive(
        dark: .black,
        light: UIColor(red: 0.98, green: 0.976, blue: 0.968, alpha: 1))
    /// Elevated surfaces: cards, keys, bars.
    static let surface = adaptive(
        dark: UIColor(white: 0.11, alpha: 1),
        light: UIColor(red: 0.936, green: 0.93, blue: 0.916, alpha: 1))
    /// Pressed/highlighted surfaces.
    static let surfacePressed = adaptive(
        dark: UIColor(white: 0.22, alpha: 1),
        light: UIColor(red: 0.87, green: 0.862, blue: 0.842, alpha: 1))
    static let card = adaptive(
        dark: UIColor(red: 22 / 255, green: 18 / 255, blue: 14 / 255, alpha: 1),
        light: UIColor(red: 247 / 255, green: 244 / 255, blue: 238 / 255, alpha: 1))
    static let functionalSurface = adaptive(
        dark: UIColor(white: 0.08, alpha: 1),
        light: UIColor(red: 239 / 255, green: 237 / 255, blue: 234 / 255, alpha: 1))
    static let hairline = adaptive(
        dark: UIColor(red: 42 / 255, green: 32 / 255, blue: 21 / 255, alpha: 1),
        light: UIColor(red: 228 / 255, green: 225 / 255, blue: 218 / 255, alpha: 1))
    static let textPrimary = adaptive(
        dark: .white,
        light: UIColor(white: 0.1, alpha: 1))
    static let textSecondary = adaptive(
        dark: UIColor(white: 0.62, alpha: 1),
        light: UIColor(white: 0.42, alpha: 1))
    static let textTertiary = adaptive(
        dark: UIColor(white: 0.42, alpha: 1),
        light: UIColor(white: 0.56, alpha: 1))
    static let micIndicator = adaptive(
        dark: UIColor(red: 1, green: 0.58, blue: 0.12, alpha: 1),
        light: UIColor(red: 0.88, green: 0.38, blue: 0.05, alpha: 1))
    /// Destructive/error accents (relay failures, delete actions).
    static let danger = adaptive(
        dark: UIColor(red: 1, green: 0.35, blue: 0.30, alpha: 1),
        light: UIColor(red: 0.78, green: 0.19, blue: 0.15, alpha: 1))

    static let cornerRadius: CGFloat = 12
    static let heroCornerRadius: CGFloat = 24
    static let keyCornerRadius: CGFloat = 6

    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// The user's appearance choice, shared through the App Group so the keyboard
/// obeys it too — a custom keyboard inherits the *host app's* trait, which is
/// exactly wrong for someone forcing light because their display struggles
/// with dark mode.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static var current: Appearance {
        guard let raw = Relay.defaults?.string(forKey: Relay.Key.appearance),
              let value = Appearance(rawValue: raw) else { return .system }
        return value
    }

    static func set(_ value: Appearance) {
        Relay.defaults?.set(value.rawValue, forKey: Relay.Key.appearance)
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
