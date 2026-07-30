import Foundation

/// What the Hotkey submenu shows, computed from the hotkey the daemon is
/// running and nothing else. `MenuBarController` transcribes a model into
/// `NSMenuItem`s verbatim; the ordering, the labels, the checkmark, and the
/// restart caption all live here, where a unit test can reach them without a
/// screen.
///
/// The caption is "applies on restart" because nothing re-arms the event tap
/// live: `HotkeyMonitor` is started once with one `Hotkey` and the pick only
/// changes what `StartupResolution.hotkey` resolves next launch. Re-arming
/// the tap on a pick is a known follow-up (upstream PR #7 does it), not
/// attempted here — this submenu stays honest about today's behaviour.
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
    public let caption: String

    /// The check sits on `current` — the key the running tap is armed with,
    /// resolved at startup from flag, config and the Fn default.
    public static func compute(current: Hotkey) -> HotkeyMenuModel {
        HotkeyMenuModel(
            items: Hotkey.allCases.map { hotkey in
                Item(title: hotkey.label,
                     hotkey: hotkey,
                     checked: hotkey == current)
            },
            caption: "applies on restart")
    }
}
