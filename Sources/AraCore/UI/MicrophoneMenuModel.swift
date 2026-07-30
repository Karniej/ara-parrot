import Foundation

/// What the Microphone submenu shows, computed from `MicrophoneStore` state
/// and nothing else. `MenuBarController` transcribes a model into `NSMenuItem`s
/// verbatim; every labeling rule lives here, where a unit test can reach it
/// without a screen.
public struct MicrophoneMenuModel: Equatable, Sendable {
    /// One pickable row. `uid == nil` is the "System default" entry.
    public struct Item: Equatable, Sendable {
        public let title: String
        public let uid: String?
        public let checked: Bool
        public let enabled: Bool
    }

    /// An informational line above the picker, or `nil` when the picker speaks
    /// for itself. Present exactly when the checked row — if any — would
    /// misdescribe what is recording: the preferred device is disconnected and
    /// a stand-in is in use, or there is nothing to record from at all.
    public let status: String?
    public let items: [Item]

    /// The check marks the *pick*, not the wire: it sits on the device the
    /// user chose (or on "System default" when they chose nothing), even while
    /// a fallback is standing in — the status line reports the stand-in. A
    /// disconnected pick therefore checks no row at all, which is the truth.
    ///
    /// "System default" deliberately claims nothing about *which* device that
    /// is: when no default input exists the store follows the first available
    /// input under the same `.systemDefault` case, and the data cannot tell
    /// the two apart.
    public static func compute(
        devices: [MicrophoneStore.Device],
        preferredUID: String?,
        effective: MicrophoneStore.Effective
    ) -> MicrophoneMenuModel {
        var items = [Item(
            title: "System default",
            uid: nil,
            checked: preferredUID == nil,
            enabled: true)]
        for device in devices {
            items.append(Item(
                title: device.name,
                uid: device.uid,
                checked: device.uid == preferredUID,
                enabled: true))
        }

        let status: String?
        switch effective {
        case .fallback(let standIn):
            status = "preferred mic disconnected — using \(standIn.name)"
        case .none:
            status = "no microphone connected"
        case .chosen, .systemDefault:
            status = nil
        }
        return MicrophoneMenuModel(status: status, items: items)
    }
}
