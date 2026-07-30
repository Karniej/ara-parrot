import Foundation

/// What the Mode submenu shows, computed from the registered modes and the
/// session's manual override — and nothing else. `MenuBarController`
/// transcribes a model into `NSMenuItem`s verbatim; the Auto row, the
/// ordering, the checkmark, and the caption all live here, where a unit test
/// can reach them without a screen.
///
/// ## The one live submenu — and deliberately unpersisted
///
/// Unlike every restart-bound sibling, a mode pick rides the existing
/// per-utterance `manual:` parameter into `ModeResolver` (precedence:
/// `--mode` flag > this pick > frontmost app > default), so the very next
/// dictation obeys it — the caption says so. And nothing here writes the
/// config: the pick is a **session override by design**. The `mode` key in
/// `config.json` remains the startup default; persisting a passing "format
/// this one as an email" moment into it would turn a temporary hand on the
/// wheel into a permanent setting nobody remembers choosing. Auto (`manual ==
/// nil`) hands the decision back to the frontmost app. The menu's `mode:`
/// label line keeps showing what each utterance actually resolved, so a
/// manual pick losing to the `--mode` flag is visible rather than silent.
public struct ModeMenuModel: Equatable, Sendable {
    /// One pickable row. `id == nil` is the "Auto (per app)" entry — no
    /// manual override, the resolver's frontmost-app rule decides.
    public struct Item: Equatable, Sendable {
        public let title: String
        public let id: String?
        public let checked: Bool
    }

    public let items: [Item]
    public let caption: String

    /// The check marks the *override*: Auto when there is none, the picked
    /// mode's row otherwise — never the mode an utterance happened to
    /// resolve, which the label line already reports.
    public static func compute(modes: [Mode],
                               manual: String?) -> ModeMenuModel {
        var items = [Item(
            title: "Auto (per app)",
            id: nil,
            checked: manual == nil)]
        for mode in modes {
            items.append(Item(
                title: mode.id,
                id: mode.id,
                checked: mode.id == manual))
        }
        return ModeMenuModel(items: items,
                             caption: "applies to the next utterance")
    }
}
