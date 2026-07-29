import Foundation

/// Chooses the active mode. Takes the frontmost bundle identifier as a
/// parameter rather than reading NSWorkspace directly, so the precedence
/// rules are testable without a running app.
public struct ModeResolver: Sendable {
    private let registry: ModeRegistry
    private let defaultID: String

    public init(registry: ModeRegistry, defaultID: String) {
        self.registry = registry
        self.defaultID = defaultID
    }

    /// Precedence: --mode flag > menu-bar selection > frontmost app > default.
    public func resolve(override: String?, manual: String?,
                        frontmostBundleID: String?) -> Mode {
        if let override, let m = registry.mode(id: override) { return m }
        if let manual, let m = registry.mode(id: manual) { return m }
        if let bundle = frontmostBundleID,
           let m = registry.all.first(where: { $0.appBundleIDs.contains(bundle) }) {
            return m
        }
        return registry.mode(id: defaultID)
            ?? registry.mode(id: "default")
            ?? ModeRegistry.builtIns[1]
    }
}
