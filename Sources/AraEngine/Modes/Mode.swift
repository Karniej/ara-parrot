import Foundation

/// A named output style. A mode is just a rewrite instruction plus the
/// metadata needed to pick it automatically.
public struct Mode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let prompt: String
    public let appBundleIDs: [String]
    public let usesLLM: Bool

    /// How aggressively this utterance is edited. Not part of a mode's
    /// identity — the registry's built-ins are all defined at `.medium` — but
    /// carried *on* the mode because the mode is the one value that already
    /// travels from the session through `FormatterChain` into all three model
    /// formatters and `TranscriptPrompt`. `DictationSession` stamps the
    /// configured intensity onto the resolved mode via `applying(cleanup:)`;
    /// nothing downstream needs to know the config exists.
    ///
    /// That stamp is unconditional: the configured intensity overwrites
    /// whatever value the mode carried, so a per-mode `cleanup` in a mode
    /// definition is silently ignored today. Harmless while every built-in is
    /// defined at the `.medium` default, but the day user-defined modes load
    /// from disk, `applying(cleanup:)` needs a policy for which value wins —
    /// decide it then, not in a bug report.
    public let cleanup: CleanupIntensity

    public init(id: String, name: String, prompt: String,
                appBundleIDs: [String], usesLLM: Bool,
                cleanup: CleanupIntensity = .medium) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.appBundleIDs = appBundleIDs
        self.usesLLM = usesLLM
        self.cleanup = cleanup
    }

    /// The same mode at the given intensity.
    ///
    /// `cleanup: none` means "no language model", and it reaches
    /// `FormatterChain` as `usesLLM == false` — the exact property verbatim
    /// mode already routes through — so the chain's routing, deadline and
    /// fallback logic are untouched and the rules floor still runs. The
    /// conjunction goes one way only: an intensity can switch the model off,
    /// but no intensity can switch it on for a mode that never wanted one.
    public func applying(cleanup: CleanupIntensity) -> Mode {
        Mode(id: id, name: name, prompt: prompt, appBundleIDs: appBundleIDs,
             usesLLM: usesLLM && cleanup != .none, cleanup: cleanup)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, appBundleIDs, usesLLM, cleanup
    }

    /// Hand-written only for `cleanup`: a mode serialised before the key
    /// existed — or a future user-defined mode that does not care — decodes at
    /// the default rather than failing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        appBundleIDs = try c.decode([String].self, forKey: .appBundleIDs)
        usesLLM = try c.decode(Bool.self, forKey: .usesLLM)
        cleanup = try c.decodeIfPresent(CleanupIntensity.self, forKey: .cleanup)
            ?? .medium
    }
}
