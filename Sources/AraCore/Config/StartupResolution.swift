import Foundation

/// Resolves the settings that can come from either a CLI flag or `config.json`.
///
/// The spec's precedence is **CLI flags > config > defaults**, and until this
/// existed the daemon implemented only "CLI flag > default" for `hotkey` and
/// `model`: both keys decoded, were asserted by a test, were documented in the
/// spec, and were then never read. A user who followed the documentation and put
/// `"hotkey": "right-command"` in their config got Fn — which is precisely the
/// user the non-Apple-keyboard hotkey work exists to serve, silently getting the
/// key that does not work on their keyboard.
///
/// It lives in the library, not in `Run`, for the reason `Pipeline` does: the
/// resolution is the part with rules in it, and `Run.run()` cannot be called
/// from a test.
///
/// ## Bad flag versus bad config
///
/// A flag the user just typed is worth rejecting: they can retype it, and the
/// process has printed the valid values. A bad *file* is not worth refusing to
/// run over — exiting leaves the daemon unusable until the file is edited, over
/// something with a perfectly good default. So a config value that does not
/// parse warns on stderr and falls back, matching what `Run` already does for
/// `config.mode`. This is the same rule in three places now; it is the project's
/// convention, not a per-field decision.
public enum StartupResolution {
    /// The outcome of resolving `--model` / `config.model`.
    ///
    /// A case rather than an optional plus a side channel because the caller has
    /// three distinct jobs: run, exit 1 with a usage hint, or exit 1 because the
    /// binary itself has no models registered.
    public enum ModelChoice {
        case chosen(TranscriptionModel)
        /// `--model <id>` named something that does not exist. Fatal.
        case unknownFlag(String)
        /// The registry is empty — a build defect, not a user error.
        case noModelsRegistered
    }

    /// Push-to-talk key: flag, then `config.hotkey`, then `.fn`.
    public static func hotkey(flag: Hotkey?,
                              config: String?,
                              warn: (String) -> Void = Config.warnToStderr) -> Hotkey {
        if let flag { return flag }
        guard let raw = config else { return .fn }
        if let parsed = Hotkey(rawValue: raw) { return parsed }
        warn("unknown hotkey in config: \(raw) — using \(Hotkey.fn.rawValue)")
        warn("known hotkeys: \(Hotkey.valueNames)")
        return .fn
    }

    /// Injection method setting: flag, then `config.inject`, then `auto`.
    public static func injection(flag: InjectionSetting?,
                                 config: String?,
                                 warn: (String) -> Void = Config.warnToStderr) -> InjectionSetting {
        if let flag { return flag }
        guard let raw = config else { return .auto }
        if let parsed = InjectionSetting(rawValue: raw) { return parsed }
        warn("unknown inject in config: \(raw) — using \(InjectionSetting.auto.rawValue)")
        warn("known values: \(InjectionSetting.valueNames)")
        return .auto
    }

    /// Transcription model: flag, then `config.model`, then the recommended one.
    public static func model(flag: String?,
                             config: String?,
                             warn: (String) -> Void = Config.warnToStderr) -> ModelChoice {
        if let flag {
            guard let found = ModelRegistry.find(flag) else { return .unknownFlag(flag) }
            return .chosen(found)
        }
        if let raw = config {
            if let found = ModelRegistry.find(raw) { return .chosen(found) }
            warn("unknown model in config: \(raw) — using the recommended model")
            warn("run `ara models list` to see options.")
        }
        guard let recommended = ModelRegistry.recommended() else { return .noModelsRegistered }
        return .chosen(recommended)
    }
}
