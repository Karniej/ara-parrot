import Foundation
import Testing
@testable import AraCore

/// Everything the Language submenu decides — computed from the running model
/// and the current setting — so the ordering, the checkmarks, what a click
/// *means*, the cost line and the caption are all reachable without a screen.
@Suite("LanguageMenuModel")
struct LanguageMenuModelTests {
    private let multilingual = ModelRegistry.find("whisper-large-v3-turbo")!
    /// Built rather than looked up: the registry offers no English-only model
    /// any more — both `.en` entries were dropped, because picking one
    /// silently turned language detection off. The submenu's English-only
    /// branch is still live code and still has to be right, so the test brings
    /// its own model instead of losing the coverage with the registry entry.
    private let englishOnly = TranscriptionModel(
        id: "whisper-base.en", displayName: "Whisper Base (English)",
        engine: .whisperKit, whisperKitID: "openai_whisper-base.en",
        sizeMB: 145, languages: ["en"], recommended: false)

    private func model(_ current: LanguageSetting,
                       on model: TranscriptionModel? = nil) -> LanguageMenuModel {
        LanguageMenuModel.compute(model: model ?? multilingual, current: current)
    }

    @Test("Automatic leads, then every offered language in catalogue order")
    func ordering() {
        let items = model(.automatic).items
        #expect(items.first?.code == nil)
        #expect(items.dropFirst().map(\.code) == LanguageCatalog.offered.map(\.code))
        #expect(items.dropFirst().map(\.title) == LanguageCatalog.offered.map(\.displayName))
    }

    @Test("the check follows the setting, and a set checks every member")
    func checks() {
        let auto = model(.automatic).items
        #expect(auto.first?.checked == true)
        #expect(auto.dropFirst().allSatisfy { !$0.checked })

        let pair = model(.monitored(["en", "pl"])).items
        #expect(pair.first?.checked == false)
        #expect(pair.filter(\.checked).map(\.code) == ["en", "pl"])
    }

    // MARK: - what a click means

    /// From Automatic, ticking one language narrows to it rather than adding
    /// to nothing: someone who ticks Polish is saying "Polish", and one
    /// language is the fast, unambiguous case.
    @Test("ticking a language while automatic narrows to that language")
    func tickFromAutomatic() throws {
        let polish = try #require(model(.automatic).items.first { $0.code == "pl" })
        #expect(polish.picked == .monitored(["pl"]))
    }

    @Test("ticking a second language adds it, in catalogue order")
    func tickAdds() throws {
        // Polish sorts after English in the catalogue, so ticking English
        // second must still produce en,pl — the config file and the menu read
        // the same way whatever route got you there.
        let english = try #require(model(.monitored(["pl"])).items.first { $0.code == "en" })
        #expect(english.picked == .monitored(["en", "pl"]))
    }

    @Test("unticking one of several removes just that one")
    func untickOne() throws {
        let english = try #require(
            model(.monitored(["en", "pl"])).items.first { $0.code == "en" })
        #expect(english.picked == .monitored(["pl"]))
    }

    /// An empty monitored set is not a setting — it could only mean automatic,
    /// so the row says so rather than storing a set nobody can act on.
    @Test("unticking the last language falls back to automatic")
    func untickLast() throws {
        let polish = try #require(model(.monitored(["pl"])).items.first { $0.code == "pl" })
        #expect(polish.picked == .automatic)
    }

    @Test("the Automatic row always picks automatic, even when already on it")
    func automaticRow() throws {
        #expect(model(.automatic).items[0].picked == .automatic)
        #expect(model(.monitored(["en", "pl"])).items[0].picked == .automatic)
    }

    /// A code hand-written into config.json that the menu does not offer must
    /// not disappear because the user ticked something in the menu.
    @Test("a monitored language the menu does not offer survives a click")
    func unlistedCodeSurvives() throws {
        let picked = try #require(
            model(.monitored(["sv"])).items.first { $0.code == "en" }).picked
        #expect(picked == .monitored(["en", "sv"]))
    }

    /// Every row round trips through the string the controller stores on the
    /// `NSMenuItem` — if it did not, a click would silently do nothing.
    @Test("every row's pick round trips through its raw value")
    func picksRoundTrip() {
        for current: LanguageSetting in [.automatic, .monitored(["pl"]),
                                         .monitored(["en", "pl", "de"])] {
            for item in model(current).items {
                #expect(LanguageSetting(rawValue: item.picked.rawValue) == item.picked)
            }
        }
    }

    // MARK: - honesty

    /// It really does apply live: the transcriber builds its `DecodingOptions`
    /// inside `transcribe`, so unlike Model, Hotkey and Engine this pick does
    /// not wait for a restart. Saying "on restart" here would be a lie in the
    /// other direction.
    @Test("the caption promises the next utterance, not a restart")
    func caption() {
        #expect(model(.automatic).caption == "applies to the next utterance")
        #expect(!model(.monitored(["pl"])).caption.contains("restart"))
    }

    @Test("the cost of each shape is stated where the choice is made")
    func status() throws {
        #expect(try #require(model(.automatic).status).contains("detecting"))
        let fixed = try #require(model(.monitored(["pl"])).status)
        #expect(fixed.contains("Polish"))
        #expect(fixed.contains("one pass"))
        // The expensive shape says so: the user pays this per utterance.
        let set = try #require(model(.monitored(["en", "pl"])).status)
        #expect(set.contains("second pass"))
        #expect(set.contains("2 languages"))
    }

    // MARK: - the English-only model

    /// Nothing here can work on `.en` weights, so nothing here pretends to:
    /// the rows are visible so the setting is discoverable, and dead so a
    /// click cannot promise something the model cannot do.
    @Test("an English-only model disables every row and says why")
    func englishOnlyIsDead() throws {
        let menu = model(.automatic, on: englishOnly)
        #expect(menu.items.allSatisfy { !$0.enabled })
        #expect(try #require(menu.status).contains("English"))
        #expect(menu.caption.contains("whisper-base.en"))
        #expect(menu.caption.contains("multilingual"))
    }

    /// The check still reports the configured setting even when it cannot be
    /// honoured — the startup warning is what says it cannot, and a menu that
    /// showed a different setting from the file would be its own bug.
    @Test("an English-only model still shows what the config says")
    func englishOnlyStillReflectsConfig() {
        let menu = model(.monitored(["pl"]), on: englishOnly)
        #expect(menu.items.filter(\.checked).map(\.code) == ["pl"])
    }
}
