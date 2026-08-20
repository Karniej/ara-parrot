import Foundation

/// What the Hotkey submenu shows, computed from the hotkey the daemon is
/// running and nothing else. `MenuBarController` transcribes a model into
/// `NSMenuItem`s verbatim; the ordering, the labels, the checkmark, and the
/// restart caption all live here, where a unit test can reach them without a
/// screen.
///
/// There is no caption. There used to be one — "applies on restart" — because
/// a pick wrote `config.json` and nothing else, and the armed tap kept
/// answering to the old key until the next launch. `HotkeyMonitor.rearm` now
/// makes the pick true the moment it is made, and a caption describing a wait
/// that no longer happens would be the same lie pointed the other way.
/// `caption` stays in the type as an optional so the submenu keeps one place
/// to say something if it ever needs to again.
public struct HotkeyMenuModel: Equatable, Sendable {
    /// One pickable key, shown under its human label ("right ⌘") while the
    /// pick persists the config spelling ("right-command") via
    /// `Config.persistHotkey` — the same split `Hotkey` itself maintains
    /// between `label` and `rawValue`.
    public struct Item: Equatable, Sendable {
        public let title: String
        public let hotkey: Hotkey
        public let checked: Bool
    }

    public let items: [Item]
    public let caption: String?

    /// The check sits on `current` — the key the running detector is armed
    /// with, resolved at startup from flag, config and the Fn default, and
    /// re-armed by every pick after that.
    public static func compute(current: Hotkey) -> HotkeyMenuModel {
        HotkeyMenuModel(
            items: Hotkey.allCases.map { hotkey in
                Item(title: hotkey.label,
                     hotkey: hotkey,
                     checked: hotkey == current)
            },
            caption: nil)
    }
}
