import Foundation

/// Loads the engine's user-editable state — dictionary, snippets, intensity —
/// from the App Group container (`ConfigLocation` already points there on
/// iOS), with the macOS byte-identical JSON formats. Both processes use this;
/// the keyboard reloads lazily on each invocation rather than caching across
/// them (extension processes persist — retained state is a jetsam vector).
struct EngineProvider {
    /// Warnings surface in the app's UI; from the keyboard they go nowhere,
    /// which is fine — the app is where files get edited.
    static func loadDictionary() -> LocalDictionary {
        ensureStarterFiles()
        return LocalDictionary.load(from: LocalDictionary.defaultURL, warn: { _ in })
    }

    static func loadSnippets() -> Snippets {
        ensureStarterFiles()
        return Snippets.load(from: Snippets.defaultURL, warn: { _ in })
    }

    static func intensity() -> CleanupIntensity {
        guard let raw = Relay.defaults?.string(forKey: Relay.Key.intensity),
              let value = CleanupIntensity(rawValue: raw) else { return .medium }
        return value
    }

    static func set(intensity: CleanupIntensity) {
        Relay.defaults?.set(intensity.rawValue, forKey: Relay.Key.intensity)
    }

    static func hapticsEnabled() -> Bool {
        // Default on: object(forKey:) is nil until the user ever toggles.
        (Relay.defaults?.object(forKey: Relay.Key.haptics) as? Bool) ?? true
    }

    static func set(hapticsEnabled: Bool) {
        Relay.defaults?.set(hapticsEnabled, forKey: Relay.Key.haptics)
    }

    /// The default mode, at the configured intensity. iOS has no per-app
    /// modes — keyboards cannot identify their host app.
    static func mode() -> Mode {
        ModeRegistry.defaultMode.applying(cleanup: intensity())
    }

    private static func ensureStarterFiles() {
        let dir = ConfigLocation.directory
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        _ = try? LocalDictionary.createStarterFileIfAbsent(at: LocalDictionary.defaultURL)
        _ = try? Snippets.createStarterFileIfAbsent(at: Snippets.defaultURL)
    }
}
