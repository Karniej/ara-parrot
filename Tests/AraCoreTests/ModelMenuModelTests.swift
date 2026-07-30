import Foundation
import Testing
@testable import AraCore

/// The Model submenu's contents are a pure function of the registry, the
/// running model, and whether the formatting model is on disk —
/// `ModelMenuModel.compute` — so titles, the checkmark, the caption, and the
/// formatter line are all checked here, off-screen. `MenuBarController` only
/// transcribes a model into `NSMenuItem`s.
@Suite("Model menu model")
struct ModelMenuModelTests {
    private static func model(_ id: String, sizeMB: Int) -> TranscriptionModel {
        TranscriptionModel(id: id, displayName: id, engine: .whisperKit,
                           whisperKitID: nil, sizeMB: sizeMB,
                           languages: ["en"], recommended: false)
    }

    @Test("every registered model is listed, in registry order, with its size")
    func registryOrderAndTitles() {
        let model = ModelMenuModel.compute(
            models: [Self.model("whisper-base.en", sizeMB: 145),
                     Self.model("whisper-large-v3-turbo", sizeMB: 1620)],
            currentID: "whisper-base.en",
            formatterDownloaded: true)
        #expect(model.items.map(\.title) == [
            "whisper-base.en · 145 MB",
            "whisper-large-v3-turbo · 1620 MB",
        ])
        #expect(model.items.map(\.id) == [
            "whisper-base.en", "whisper-large-v3-turbo",
        ])
    }

    @Test("the running model carries the check, and only it")
    func checkmarkPlacement() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared,
            currentID: "whisper-small.en",
            formatterDownloaded: true)
        #expect(model.items.map(\.checked)
                == ModelRegistry.shared.map { $0.id == "whisper-small.en" })
        #expect(model.items.filter(\.checked).count == 1)
    }

    /// The transcriber is built around one model at startup, and a pick that
    /// names a model not on disk is fetched by the next launch's warm-up —
    /// both halves belong in the caption.
    @Test("the caption says a pick applies on restart and may download")
    func restartCaption() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared, currentID: "whisper-base.en",
            formatterDownloaded: true)
        #expect(model.caption
                == "applies on restart — downloads if not on disk")
    }

    @Test("a downloaded formatting model is stated, not offered")
    func formatterDownloaded() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared, currentID: "whisper-base.en",
            formatterDownloaded: true)
        #expect(model.formatter.title == "Formatting model: ✓ downloaded")
        #expect(!model.formatter.offersDownload)
    }

    /// The menu cannot download 900 MB behind the user's back, so the item is
    /// an offer that explains itself — size and restart semantics up front.
    /// Clicking it shows the exact command; nothing is fetched in-process.
    @Test("a missing formatting model is offered, size and restart named")
    func formatterMissing() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared, currentID: "whisper-base.en",
            formatterDownloaded: false)
        #expect(model.formatter.title
                == "Download formatting model… (900 MB, applies on restart)")
        #expect(model.formatter.offersDownload)
    }
}
