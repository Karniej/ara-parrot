import Foundation

/// The `DecodingOptions` a model kind and a language setting produce for an
/// utterance's **first** decoding pass — the whole of the fix, as a pure
/// function.
///
/// It is a function rather than four lines inside `transcribe` because the
/// three cases are not symmetric and the asymmetry is the interesting part:
/// an English-only model must never detect, a multilingual model on `auto`
/// must always detect, and a pinned language must not. Inline, none of that is
/// reachable by a test; the bug being fixed here is precisely a decoding
/// option nobody could see.
public struct LanguagePlan: Equatable, Sendable {
    /// `DecodingOptions.language` — `nil` asks WhisperKit to decide.
    public let language: String?
    /// `DecodingOptions.detectLanguage`. WhisperKit's default is **false**
    /// (`Configurations.swift:226`: `detectLanguage ?? !usePrefillPrompt`,
    /// and `usePrefillPrompt` defaults to true), which is why a multilingual
    /// model transcribed everything as English until this existed.
    public let detectLanguage: Bool
    /// Whether a second decoder pass may follow — true only for a
    /// multilingual model with more than one monitored language, and then
    /// only on an utterance whose detected language is not the previous one's.
    /// The user pays for it in latency, so it is stated rather than
    /// discovered.
    public let refines: Bool
    /// One line for stderr at startup when the settings cannot do what they
    /// say. Only ever non-nil for a non-English language on an English-only
    /// model.
    public let warning: String?

    public static func resolve(model: TranscriptionModel,
                               setting: LanguageSetting) -> LanguagePlan {
        // An English-only model has one language and no language token to
        // choose. Detection would cost a decoder pass to learn what the
        // weights already guarantee, and `language: "pl"` would be a request
        // the model physically cannot serve. So: today's behaviour exactly —
        // `DecodingOptions()`'s own defaults — plus, when the config asked for
        // something else, a line saying so.
        guard !model.isEnglishOnly else {
            let foreign = (setting.monitoredCodes ?? []).filter { $0 != "en" }
            guard !foreign.isEmpty else {
                return LanguagePlan(language: nil, detectLanguage: false,
                                    refines: false, warning: nil)
            }
            let alternatives = ModelRegistry.shared
                .filter { !$0.isEnglishOnly }
                .map(\.id)
                .joined(separator: ", ")
            return LanguagePlan(
                language: nil, detectLanguage: false, refines: false,
                warning: "language \(foreign.joined(separator: ", ")) cannot work "
                    + "with \(model.id): it is an English-only model and can only "
                    + "produce English. Dictation stays in English. Switch to a "
                    + "multilingual model (\(alternatives)) or set language to "
                    + "\"en\" or \"auto\".")
        }

        switch setting {
        case .automatic:
            // The fix: without this, `TranscribeTask.swift:312`'s
            // `options.detectLanguage` guard is never satisfied and every
            // utterance decodes with the English prefill.
            return LanguagePlan(language: nil, detectLanguage: true,
                                refines: false, warning: nil)
        case .monitored(let codes) where codes.count == 1:
            // Pinning beats detecting when the user knows: one pass, and a
            // two-word utterance cannot be misread.
            return LanguagePlan(language: codes[0], detectLanguage: false,
                                refines: false, warning: nil)
        case .monitored:
            return LanguagePlan(language: nil, detectLanguage: true,
                                refines: true, warning: nil)
        }
    }
}
