import Foundation

/// What the Cleanup submenu shows, computed from the configured intensity and
/// nothing else. `MenuBarController` transcribes a model into `NSMenuItem`s
/// verbatim; the ordering, the checkmark, and the honesty caption all live
/// here, where a unit test can reach them without a screen.
public struct CleanupMenuModel: Equatable, Sendable {
    /// One pickable row: the intensity's config spelling, and whether it is
    /// the one the config currently holds.
    public struct Item: Equatable, Sendable {
        public let title: String
        public let intensity: CleanupIntensity
        public let checked: Bool
    }

    public let items: [Item]

    /// The disabled line under the choices. The session's cleanup intensity
    /// is stamped when the daemon builds it at startup, so a pick persists to
    /// the config but takes effect on the next launch — unlike everything
    /// else in this menu, which applies to the next utterance. A submenu that
    /// stayed silent about that would look broken the moment someone dictated
    /// after picking; the caption is the truth, stated where the choice is
    /// made.
    public let caption: String

    /// The check sits on `current` — which is what `Config.load` resolved,
    /// so an absent `cleanup` key checks medium, the intensity the daemon is
    /// actually running at.
    public static func compute(current: CleanupIntensity) -> CleanupMenuModel {
        CleanupMenuModel(
            items: CleanupIntensity.allCases.map { intensity in
                Item(title: intensity.rawValue,
                     intensity: intensity,
                     checked: intensity == current)
            },
            caption: "applies on restart")
    }
}
