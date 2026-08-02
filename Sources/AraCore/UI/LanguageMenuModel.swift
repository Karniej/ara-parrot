import Foundation

/// What the Language submenu shows, computed from the running model and the
/// current setting and nothing else. `MenuBarController` transcribes a model
/// into `NSMenuItem`s verbatim; every rule — the ordering, the checkmarks, what
/// a click *means*, the cost line, and the caption — lives here, where a unit
/// test can reach it without a screen.
///
/// ## Why the rows are checkboxes, not a radio group
///
/// Unlike Cleanup, Hotkey and Engine, the setting is a *set*: someone who
/// dictates in two languages says so by ticking both. So each row's job is to
/// answer "what would the setting be if I clicked this?", and it answers by
/// carrying the whole resulting `LanguageSetting` in `picked`. The controller
/// then needs no rules of its own — it stores `picked.rawValue` on the item and
/// hands it back on click.
public struct LanguageMenuModel: Equatable, Sendable {
    /// One row: the Automatic row (`code == nil`) or a language.
    public struct Item: Equatable, Sendable {
        public let title: String
        /// The language this row is about; `nil` for the Automatic row.
        public let code: String?
        public let checked: Bool
        public let enabled: Bool
        /// The setting a click on this row produces. Precomputed so the
        /// toggle rules are testable rather than living in an `@objc` handler.
        public let picked: LanguageSetting
    }

    /// An informational line above the rows, or `nil` when the rows speak for
    /// themselves. Present when the setting costs extra decoder passes, or
    /// when the running model makes the whole submenu moot.
    public let status: String?
    public let items: [Item]

    /// The line under the rows. "next utterance", not "on restart": unlike
    /// every other persisted submenu, this one really does apply live — the
    /// transcriber builds its `DecodingOptions` inside `transcribe`, so
    /// `WhisperKitTranscriber.setLanguage` lands between utterances and the
    /// next dictation uses it.
    public let caption: String

    /// - Parameter switching: what the Model submenu is doing, if anything.
    ///   The caption's job when the running model is English-only is to say
    ///   what would unlock these rows — so when a multilingual model is already
    ///   loading, telling the user to pick one is worse than saying nothing.
    public static func compute(model: TranscriptionModel,
                               current: LanguageSetting,
                               switching: ModelSwitch = .settled) -> LanguageMenuModel {
        // An English-only model has nothing to choose: no language token, no
        // detection, no second pass. Showing a live picker over it would be a
        // lie, so the rows are visible (so the user can see what the setting
        // *would* offer) and every one of them is dead.
        let usable = !model.isEnglishOnly

        var items = [Item(
            title: "Automatic (detect any language)",
            code: nil,
            checked: current == .automatic,
            enabled: usable,
            picked: .automatic)]

        let monitored = current.monitoredCodes ?? []
        for language in LanguageCatalog.offered {
            let isOn = monitored.contains(language.code)
            items.append(Item(
                title: language.displayName,
                code: language.code,
                checked: isOn,
                enabled: usable,
                picked: toggling(language.code, in: monitored, isOn: isOn)))
        }

        return LanguageMenuModel(
            status: status(model: model, current: current),
            items: items,
            caption: caption(model: model, usable: usable, switching: switching))
    }

    /// The line under the rows.
    ///
    /// The English-only wording is conditional on there being nothing in
    /// flight, because "pick a multilingual model" is exactly the instruction a
    /// user who *just did that* does not need. While one loads, the caption
    /// says what is happening and that these rows are waiting on it.
    private static func caption(model: TranscriptionModel, usable: Bool,
                                switching: ModelSwitch) -> String {
        if usable { return "applies to the next utterance" }
        switch switching {
        case .loading(let target):
            return "loading \(target) — these unlock when it is ready"
        case .failed(let target):
            return "\(target) failed to load — still running \(model.id), "
                + "which is English-only"
        case .settled:
            return "\(model.id) is English-only — pick a multilingual model to "
                + "dictate another language"
        }
    }

    /// What clicking a language row produces.
    ///
    /// Ticking a language while on Automatic *narrows* to just that language
    /// rather than adding to nothing: someone who ticks Polish from Automatic
    /// is saying "Polish", and the one-language case is the fast, unambiguous
    /// one. Unticking the last remaining language falls back to Automatic,
    /// because an empty monitored set is not a setting — it would have to mean
    /// Automatic anyway, and saying so is better than storing it.
    private static func toggling(_ code: String, in monitored: [String],
                                 isOn: Bool) -> LanguageSetting {
        if isOn {
            let remaining = monitored.filter { $0 != code }
            return remaining.isEmpty ? .automatic : .monitored(remaining)
        }
        guard !monitored.isEmpty else { return .monitored([code]) }
        // Keep the catalogue's order rather than click order, so the config
        // file and the menu read the same way whatever route got you there.
        let added = monitored + [code]
        let ordered = LanguageCatalog.offered.map(\.code).filter(added.contains)
        // A hand-written code the menu does not offer must not vanish because
        // the user ticked something else.
        let unlisted = added.filter { !ordered.contains($0) }
        return .monitored(ordered + unlisted)
    }

    /// The honest cost line. Two or more monitored languages means the
    /// transcriber runs a second decoder pass on any utterance whose detected
    /// language is not the one the last utterance used — measured at roughly
    /// double the transcription phase on the large model (0.9s → 1.8s for six
    /// seconds of speech). The user pays it, so it is said where the choice is
    /// made rather than only in a doc.
    private static func status(model: TranscriptionModel,
                               current: LanguageSetting) -> String? {
        guard !model.isEnglishOnly else {
            return "\(model.id) can only produce English"
        }
        switch current {
        case .automatic:
            return "detecting every utterance — pick languages to make it faster"
        case .monitored(let codes) where codes.count == 1:
            return "fixed to \(LanguageCatalog.displayName(for: codes[0])) — one pass, fastest"
        case .monitored(let codes):
            return "\(codes.count) languages — a second pass when the language changes"
        }
    }
}
