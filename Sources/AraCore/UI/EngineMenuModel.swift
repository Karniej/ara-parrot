import Foundation

/// What the Engine submenu shows, computed from the engine the daemon is
/// running and whether the startup keychain read produced an API key — and
/// nothing else. `MenuBarController` transcribes a model into `NSMenuItem`s
/// verbatim; the ordering, the checkmark, the cloud item's honesty suffix,
/// and the restart caption all live here, where a unit test can reach them
/// without a screen.
///
/// ## Why `hasAPIKey` is a parameter and never a keychain read
///
/// A cloud engine with no key silently formats with the rules floor, so the
/// cloud row must not imply a key exists. But the menu must not find out by
/// asking: `Keychain.readPassword` can raise a blocking unlock or Allow/Deny
/// prompt (see its doc comment — for this unsigned binary that is the normal
/// path, not a corner case), and a submenu that pops a password dialog on
/// open would be worse than a missing suffix. `Run` already reads the key
/// exactly once at startup, on its own thread; this model is computed from
/// that read's result, carried by value. The suffix therefore describes what
/// the *running daemon* has — which is also the only key it will ever use,
/// since the read is deliberately once-per-process.
public struct EngineMenuModel: Equatable, Sendable {
    /// One pickable engine: the config spelling (plus the cloud honesty
    /// suffix), and whether it is the engine the daemon is running.
    public struct Item: Equatable, Sendable {
        public let title: String
        public let engine: Engine
        public let checked: Bool
    }

    public let items: [Item]

    /// The disabled line under the choices, `CleanupMenuModel`'s pattern: the
    /// formatter chain is assembled — and the key read — at startup, so a
    /// pick persists to the config and takes effect on the next launch.
    public let caption: String

    /// The check sits on `current` — what `Config.load` resolved, which is
    /// the chain the daemon actually assembled.
    public static func compute(current: Engine,
                               hasAPIKey: Bool) -> EngineMenuModel {
        EngineMenuModel(
            items: Engine.allCases.map { engine in
                var title = engine.rawValue
                if engine == .cloud, !hasAPIKey {
                    title += " (no API key set)"
                }
                return Item(title: title,
                            engine: engine,
                            checked: engine == current)
            },
            caption: "applies on restart")
    }
}
