import Foundation
import Testing
import WhisperKit
@testable import AraCore

/// The catalogue of languages a user may name, and the parsing that turns what
/// they typed into codes WhisperKit will accept.
@Suite("LanguageCatalog")
struct LanguageCatalogTests {
    /// The set is WhisperKit's own, not a copy: a WhisperKit upgrade that adds
    /// a language needs no edit here, and one that drops a language breaks
    /// this test rather than a user's dictation.
    @Test("the supported set is WhisperKit's own tokenizer set")
    func supportedSetIsWhisperKits() {
        #expect(LanguageCatalog.supportedCodes == Constants.languageCodes)
        #expect(LanguageCatalog.supportedCodes.contains("en"))
        #expect(LanguageCatalog.supportedCodes.contains("pl"))
        #expect(LanguageCatalog.supportedCodes.count > 90)
    }

    @Test("parsing lower-cases, trims, and de-duplicates in first-seen order")
    func parseNormalises() throws {
        #expect(try LanguageCatalog.parse("EN, pl, en, DE") == ["en", "pl", "de"])
        #expect(try LanguageCatalog.parse(" pl ") == ["pl"])
    }

    /// The validation that matters: a typo is rejected when the config is
    /// read, not when the user is mid-utterance. WhisperKit would carry
    /// `"pll"` all the way into the decoder prefill before it mattered.
    @Test("an unknown code is rejected, and the error names it")
    func rejectsUnknown() {
        #expect(throws: LanguageSelectionError.unsupportedCodes(["pll"])) {
            try LanguageCatalog.parse("en,pll")
        }
        #expect(throws: LanguageSelectionError.unsupportedCodes(["polish"])) {
            try LanguageCatalog.parse("polish")
        }
    }

    @Test("an empty selection is rejected rather than silently meaning auto")
    func rejectsEmpty() {
        #expect(throws: LanguageSelectionError.emptySelection) {
            try LanguageCatalog.validate([])
        }
        #expect(throws: LanguageSelectionError.emptySelection) {
            try LanguageCatalog.parse("  ")
        }
    }

    @Test("every offered language is one WhisperKit accepts, with a name")
    func offeredAreValid() {
        for language in LanguageCatalog.offered {
            #expect(LanguageCatalog.supportedCodes.contains(language.code),
                    "\(language.code) is not a WhisperKit language code")
            #expect(!language.displayName.isEmpty)
        }
    }

    /// The user who reported the bug dictates Polish; English is what every
    /// other default in this daemon assumes. Neither may fall out of the
    /// curated list by accident — and the list stays a menu, not a catalogue.
    @Test("the offered list is curated, ordered, and includes English and Polish")
    func offeredCurated() {
        let codes = LanguageCatalog.offered.map(\.code)
        #expect(codes.contains("en"))
        #expect(codes.contains("pl"))
        #expect(codes.count < 25)
        #expect(Set(codes).count == codes.count)
        let names = LanguageCatalog.offered.map(\.displayName)
        #expect(names == names.sorted())
    }

    @Test("display names are looked up by code, and unknown codes render as themselves")
    func displayNames() {
        #expect(LanguageCatalog.displayName(for: "pl") == "Polish")
        #expect(LanguageCatalog.displayName(for: "en") == "English")
        #expect(LanguageCatalog.displayName(for: "haw") == "haw")
    }
}

/// The config value: what spellings are accepted, and what a menu pick round
/// trips through.
@Suite("LanguageSetting")
struct LanguageSettingTests {
    @Test("auto is the automatic case, both ways")
    func autoSpelling() {
        #expect(LanguageSetting(rawValue: "auto") == .automatic)
        #expect(LanguageSetting(rawValue: "Auto") == .automatic)
        #expect(LanguageSetting.automatic.rawValue == "auto")
    }

    @Test("one code monitors exactly that language")
    func singleCode() {
        #expect(LanguageSetting(rawValue: "pl") == .monitored(["pl"]))
        #expect(LanguageSetting.monitored(["pl"]).rawValue == "pl")
    }

    @Test("several codes monitor the set, order preserved")
    func severalCodes() {
        #expect(LanguageSetting(rawValue: "en,pl") == .monitored(["en", "pl"]))
        #expect(LanguageSetting(rawValue: "EN, pl ") == .monitored(["en", "pl"]))
        #expect(LanguageSetting.monitored(["en", "pl"]).rawValue == "en,pl")
    }

    @Test("a nonsense spelling is nil rather than a guess")
    func rejectsNonsense() {
        #expect(LanguageSetting(rawValue: "pll") == nil)
        #expect(LanguageSetting(rawValue: "") == nil)
        #expect(LanguageSetting(rawValue: "automatic") == nil)
        #expect(LanguageSetting(rawValue: "auto,pl") == nil)
    }

    @Test("every raw value round trips")
    func roundTrip() {
        for setting: LanguageSetting in [.automatic, .monitored(["pl"]),
                                         .monitored(["en", "pl", "de"])] {
            #expect(LanguageSetting(rawValue: setting.rawValue) == setting)
        }
    }

    @Test("monitoring is a membership question the menu can ask")
    func membership() {
        #expect(LanguageSetting.monitored(["en", "pl"]).monitors("pl"))
        #expect(!LanguageSetting.monitored(["en", "pl"]).monitors("de"))
        // Automatic monitors nothing: it accepts whatever WhisperKit detects.
        #expect(!LanguageSetting.automatic.monitors("pl"))
        #expect(LanguageSetting.automatic.monitoredCodes == nil)
        #expect(LanguageSetting.monitored(["en"]).monitoredCodes == ["en"])
    }

    @Test("the warning text names spellings a user can copy")
    func validNamesAreUsable() {
        #expect(LanguageSetting.validNames.contains("auto"))
        #expect(LanguageSetting.validNames.contains("pl"))
        #expect(LanguageSetting.validNames.contains("en"))
    }
}

/// Which `DecodingOptions` a model kind and a language setting produce for the
/// first decoding pass. Three shapes, deliberately not symmetric.
@Suite("LanguagePlan")
struct LanguagePlanTests {
    private let englishOnly = TranscriptionModel(
        id: "whisper-base.en", displayName: "Whisper Base (English)",
        engine: .whisperKit, whisperKitID: "openai_whisper-base.en",
        sizeMB: 145, languages: ["en"], recommended: true)

    private let multilingual = TranscriptionModel(
        id: "whisper-large-v3-turbo", displayName: "Whisper Large v3 Turbo",
        engine: .whisperKit, whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
        sizeMB: 1620, languages: ["multi"], recommended: false)

    /// Every offered model is multilingual now — the two `.en` entries were
    /// dropped, because picking one silently turned language detection off.
    /// The English-only *classification* still has to work: `LanguagePlan` and
    /// `LanguageMenuModel` both branch on it, the stand-in in `WarmupLadder`
    /// depends on being multilingual, and an `.en` model added back must be
    /// recognised rather than quietly treated as multilingual.
    @Test("every offered model is multilingual, and the classifier still works")
    func registryClassification() {
        #expect(!ModelRegistry.shared.isEmpty)
        for model in ModelRegistry.shared {
            #expect(!model.isEnglishOnly, "\(model.id) is English-only")
        }
        #expect(!ModelRegistry.bootstrap.isEnglishOnly)
        #expect(englishOnly.isEnglishOnly)
        #expect(!multilingual.isEnglishOnly)
    }

    /// The bug, pinned: a multilingual model on `auto` must ask WhisperKit to
    /// detect. Without `detectLanguage: true` the branch at
    /// TranscribeTask.swift:312 is never taken and every utterance decodes as
    /// English.
    @Test("multilingual + auto detects, and needs no second pass")
    func multilingualAuto() {
        let plan = LanguagePlan.resolve(model: multilingual, setting: .automatic)
        #expect(plan.language == nil)
        #expect(plan.detectLanguage)
        #expect(!plan.refines)
        #expect(plan.warning == nil)
    }

    /// Pinning is faster and more reliable than detecting when the user knows:
    /// one decoder pass, and no chance of a two-word utterance being guessed
    /// wrong.
    @Test("multilingual + one monitored language pins it")
    func multilingualPinned() {
        let plan = LanguagePlan.resolve(model: multilingual, setting: .monitored(["pl"]))
        #expect(plan.language == "pl")
        #expect(!plan.detectLanguage)
        #expect(!plan.refines)
        #expect(plan.warning == nil)
    }

    /// The expensive shape, and the reason `refines` exists: the first pass
    /// detects, and the transcriber may then run up to two more.
    @Test("multilingual + several monitored languages detects, then refines")
    func multilingualMonitoredSet() {
        let plan = LanguagePlan.resolve(model: multilingual, setting: .monitored(["en", "pl"]))
        #expect(plan.language == nil)
        #expect(plan.detectLanguage)
        #expect(plan.refines)
        #expect(plan.warning == nil)
    }

    /// Detection on an English-only model is meaningless — it has no other
    /// language to produce — and costs a decoder pass to learn nothing.
    @Test("English-only never detects and never refines, whatever the setting")
    func englishOnlyNeverDetects() {
        for setting: LanguageSetting in [.automatic, .monitored(["en"]),
                                         .monitored(["pl"]), .monitored(["en", "pl"])] {
            let plan = LanguagePlan.resolve(model: englishOnly, setting: setting)
            #expect(!plan.detectLanguage)
            #expect(plan.language == nil)
            #expect(!plan.refines)
        }
    }

    /// Today's behaviour, exactly: `DecodingOptions()` defaults to
    /// `language: nil` and `detectLanguage: false`, which is what an
    /// English-only model on the default setting still produces — silently.
    @Test("English-only + auto is today's behaviour, without a word")
    func englishOnlyAutoIsSilent() {
        let plan = LanguagePlan.resolve(model: englishOnly, setting: .automatic)
        #expect(plan.warning == nil)
    }

    @Test("English-only + en is honoured without a complaint")
    func englishOnlyEnglishIsSilent() {
        #expect(LanguagePlan.resolve(model: englishOnly,
                                     setting: .monitored(["en"])).warning == nil)
    }

    /// This combination is a lie and the user must be told: they will
    /// otherwise dictate Polish into a model that can only answer in English
    /// and blame the detection.
    @Test("English-only + a foreign language warns, naming both and a way out")
    func englishOnlyForeignWarns() throws {
        let plan = LanguagePlan.resolve(model: englishOnly, setting: .monitored(["en", "pl"]))
        let warning = try #require(plan.warning)
        #expect(warning.contains("pl"))
        #expect(warning.contains("whisper-base.en"))
        // Actionable, not merely a rejection: name a model that can do it.
        #expect(warning.contains("whisper-large-v3-turbo"))
    }
}

/// The refinement rules, ported as specifications from `aivars/parrot`'s
/// `LanguagePolicyTests` (MIT, © Andrew Jones) — see `LanguagePolicy`.
@Suite("LanguagePolicy")
struct LanguagePolicyTests {
    // MARK: - comparisonLanguage

    @Test("a switch away from the last language earns a comparison pass")
    func comparisonWhenDetectionSwitches() {
        #expect(LanguagePolicy.comparisonLanguage(
            detected: "pl", lastUsed: "en", monitored: ["en", "pl"]) == "en")
    }

    @Test("a detection outside the monitored set needs no comparison")
    func noComparisonOutsideMonitored() {
        #expect(LanguagePolicy.comparisonLanguage(
            detected: "lt", lastUsed: "en", monitored: ["en", "pl"]) == nil)
    }

    /// The common case, and the one that keeps the cost down: the user is
    /// still speaking the language they spoke last, so one pass is the whole
    /// utterance.
    @Test("no switch, no comparison — and none on the first utterance either")
    func noComparisonWhenStable() {
        #expect(LanguagePolicy.comparisonLanguage(
            detected: "en", lastUsed: "en", monitored: ["en", "pl"]) == nil)
        #expect(LanguagePolicy.comparisonLanguage(
            detected: "pl", lastUsed: nil, monitored: ["en", "pl"]) == nil)
    }

    // MARK: - selectMonitoredLanguage

    @Test("the most probable monitored language wins, ignoring unmonitored ones")
    func highestProbabilityMonitoredWins() {
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: ["en": -1.1, "pl": -0.2, "lt": -0.1],
            detected: "lt", lastUsed: nil, monitored: ["en", "pl"]) == "pl")
    }

    /// The stickiness that stops a session flapping: a marginal call goes to
    /// the language the previous utterance used.
    @Test("the last language's bias decides a near-tie")
    func biasDecidesNearTie() {
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: ["en": -0.30, "pl": -0.22],
            detected: "lt", lastUsed: "en", monitored: ["en", "pl"]) == "en")
        // …but not a clear one.
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: ["en": -0.60, "pl": -0.22],
            detected: "lt", lastUsed: "en", monitored: ["en", "pl"]) == "pl")
    }

    @Test("the bias is injectable, and zero disables the stickiness")
    func biasInjectable() {
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: ["en": -0.30, "pl": -0.22],
            detected: "lt", lastUsed: "en", monitored: ["en", "pl"],
            bias: 0) == "pl")
        #expect(LanguagePolicy.lastLanguageBias == 0.12)
    }

    /// Never nil for a non-empty monitored set: the caller has a transcript in
    /// hand and must not lose it because no probability was reported.
    @Test("a probability table that mentions nothing monitored still answers")
    func degradesRatherThanFailing() {
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: ["lt": -0.1],
            detected: "lt", lastUsed: "pl", monitored: ["en", "pl"]) == "pl")
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: [:],
            detected: nil, lastUsed: nil, monitored: ["en", "pl"]) == "en")
        #expect(LanguagePolicy.selectMonitoredLanguage(
            probabilities: [:], detected: nil, lastUsed: nil, monitored: []) == nil)
    }

    // MARK: - chooseLanguage

    @Test("the previous language wins a close confidence comparison")
    func previousWinsClose() {
        #expect(LanguagePolicy.chooseLanguage(
            detected: "pl", detectedScore: -0.42,
            alternative: "en", alternativeScore: -0.50,
            lastUsed: "en", monitored: ["en", "pl"]) == "en")
    }

    @Test("a clearly better detection overrides the previous language")
    func clearDetectionWins() {
        #expect(LanguagePolicy.chooseLanguage(
            detected: "pl", detectedScore: -0.30,
            alternative: "en", alternativeScore: -0.65,
            lastUsed: "en", monitored: ["en", "pl"]) == "pl")
    }

    @Test("a detection outside the monitored set cannot win at any confidence")
    func outsideMonitoredCannotWin() {
        #expect(LanguagePolicy.chooseLanguage(
            detected: "lt", detectedScore: -0.10,
            alternative: "pl", alternativeScore: -0.80,
            lastUsed: "pl", monitored: ["en", "pl"]) == "pl")
        #expect(LanguagePolicy.chooseLanguage(
            detected: nil, detectedScore: -0.10,
            alternative: "pl", alternativeScore: -0.80,
            lastUsed: "pl", monitored: ["en", "pl"]) == "pl")
    }
}
