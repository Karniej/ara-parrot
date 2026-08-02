import Foundation
import Testing
@testable import AraCore

@Suite("ModelLabel")
struct ModelLabelTests {
    @Test("a settled model is named plainly")
    func settled() {
        #expect(ModelLabel.text(running: "whisper-base.en", switching: .settled)
                == "model: whisper-base.en")
    }

    /// The defect: picking a model changed `config.json` and nothing visible,
    /// so the header kept naming the old model with no hint anything was
    /// pending. Both models have to appear.
    @Test("a switch in flight names both models")
    func loading() {
        let text = ModelLabel.text(running: "whisper-base.en",
                                   switching: .loading(target: "whisper-large-v3-turbo"))
        #expect(text.contains("whisper-base.en"))
        #expect(text.contains("whisper-large-v3-turbo"))
        #expect(text.contains("loading"))
    }

    @Test("a failed switch says which model failed and which is still running")
    func failed() {
        let text = ModelLabel.text(running: "whisper-base.en",
                                   switching: .failed(target: "whisper-large-v3-turbo"))
        #expect(text.contains("whisper-base.en"))
        #expect(text.contains("whisper-large-v3-turbo"))
        #expect(text.contains("failed"))
    }
}

@Suite("LanguageMenuCaption")
struct LanguageMenuCaptionTests {
    private var englishOnly: TranscriptionModel {
        ModelRegistry.find("whisper-base.en")!
    }
    private var multilingual: TranscriptionModel {
        ModelRegistry.find("whisper-large-v3-turbo")!
    }

    @Test("a multilingual model's rows apply live, whatever the switch state")
    func multilingualIsUnconditional() {
        for switching: ModelSwitch in [.settled, .loading(target: "x"),
                                       .failed(target: "x")] {
            let menu = LanguageMenuModel.compute(model: multilingual,
                                                 current: .automatic,
                                                 switching: switching)
            #expect(menu.caption == "applies to the next utterance")
        }
    }

    @Test("an English-only model with nothing pending says what to do")
    func englishOnlySettled() {
        let menu = LanguageMenuModel.compute(model: englishOnly, current: .automatic,
                                             switching: .settled)
        #expect(menu.caption.contains("English-only"))
        #expect(menu.caption.contains("pick a multilingual model"))
    }

    /// The defect this exists for: the user picks the multilingual model, opens
    /// Language, and is told to pick a multilingual model. While one is
    /// loading, the caption must not issue an instruction already carried out.
    @Test("a loading multilingual model is not answered with 'pick one'")
    func englishOnlyWhileLoading() {
        let menu = LanguageMenuModel.compute(
            model: englishOnly, current: .automatic,
            switching: .loading(target: "whisper-large-v3-turbo"))
        #expect(!menu.caption.contains("pick a multilingual model"))
        #expect(menu.caption.contains("whisper-large-v3-turbo"))
        #expect(menu.caption.contains("loading"))
    }

    @Test("a failed switch says the rows are still locked, and by what")
    func englishOnlyAfterFailure() {
        let menu = LanguageMenuModel.compute(
            model: englishOnly, current: .automatic,
            switching: .failed(target: "whisper-large-v3-turbo"))
        #expect(menu.caption.contains("failed"))
        #expect(menu.caption.contains("whisper-base.en"))
    }

    /// The rows themselves are governed by the *running* model, never by what
    /// is loading: a pick that has not landed must not enable a picker the
    /// running model cannot honour.
    @Test("rows stay disabled while the multilingual model is still loading")
    func rowsFollowTheRunningModel() {
        let menu = LanguageMenuModel.compute(
            model: englishOnly, current: .automatic,
            switching: .loading(target: "whisper-large-v3-turbo"))
        #expect(menu.items.allSatisfy { !$0.enabled })
    }
}
