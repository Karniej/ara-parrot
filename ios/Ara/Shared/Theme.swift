import SwiftUI

/// The VidNotes design standard, applied to Ara: pure-black surfaces, one
/// accent, no gradients. Every color in the app and the keyboard comes from
/// here — a hardcoded color anywhere else is a review defect.
enum Theme {
    /// Ara amber, carried over from the macOS recording pill.
    static let accent = Color(red: 1, green: 190 / 255, blue: 118 / 255)
    static let background = Color.black
    /// Elevated surfaces: cards, keys, bars.
    static let surface = Color(white: 0.11)
    /// Pressed/highlighted surfaces.
    static let surfacePressed = Color(white: 0.22)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    /// Destructive/error accents (relay failures, delete actions).
    static let danger = Color(red: 1, green: 0.35, blue: 0.30)

    static let cornerRadius: CGFloat = 12
    static let keyCornerRadius: CGFloat = 6
}
