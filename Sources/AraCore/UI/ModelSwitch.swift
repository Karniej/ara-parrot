import Foundation

/// Where a model change has got to.
///
/// Picking a model used to write `config.json` and nothing else: the saved
/// value changed, every visible piece of state kept naming the old model, and
/// the only hint that a restart was needed was a caption in a different
/// submenu from the one showing the consequence. A user who picked the
/// multilingual model and then opened Language was told, correctly but
/// uselessly, to pick a multilingual model.
///
/// So the pick now starts a real load and this says how it is going. The
/// running model is the one serving utterances — never the saved one — because
/// that is what determines what the user actually gets.
public enum ModelSwitch: Equatable, Sendable {
    /// Nothing in flight: the running model is the chosen one.
    case settled
    /// A new model is loading. The old one keeps serving utterances until it
    /// lands, so this is not a degraded state — dictation works throughout.
    case loading(target: String)
    /// The load failed and the running model is unchanged. The saved value is
    /// deliberately left alone: it is still what the user asked for, and it
    /// will be retried on the next launch.
    case failed(target: String)
}

/// The menu's `model:` line.
///
/// Separate from `MenuBarController` so the wording is unit-testable without a
/// screen, in the same spirit as the `*MenuModel` types.
public enum ModelLabel {
    public static func text(running: String, switching: ModelSwitch) -> String {
        switch switching {
        case .settled:
            return "model: \(running)"
        case .loading(let target):
            // The arrow says the old one is still in use, which is true and is
            // the reassurance worth giving: a several-minute Neural Engine
            // compile is not an outage.
            return "model: \(running) → loading \(target)…"
        case .failed(let target):
            return "model: \(running) · \(target) failed to load"
        }
    }
}
