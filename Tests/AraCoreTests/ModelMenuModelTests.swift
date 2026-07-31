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

    /// A model already on disk costs nothing to pick; one that is not costs a
    /// download the size of the row. Saying which is which *here* is the only
    /// place a user finds out before the wait rather than during it.
    @Test("every registered model is listed, in registry order, with its size")
    func registryOrderAndTitles() {
        let model = ModelMenuModel.compute(
            models: [Self.model("whisper-base.en", sizeMB: 145),
                     Self.model("whisper-large-v3-turbo", sizeMB: 1620)],
            currentID: "whisper-base.en",
            downloaded: { $0.id == "whisper-base.en" },
            formatterDownloaded: true)
        #expect(model.items.map(\.title) == [
            "whisper-base.en · 145 MB · on disk",
            "whisper-large-v3-turbo · 1.6 GB download",
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
            downloaded: { _ in true },
            formatterDownloaded: true)
        #expect(model.items.map(\.checked)
                == ModelRegistry.shared.map { $0.id == "whisper-small.en" })
        #expect(model.items.filter(\.checked).count == 1)
    }

    /// The transcriber is built around one model at startup, and a pick that
    /// names a model not on disk is fetched by the next launch's warm-up —
    /// both halves belong in the caption. So does the third cost, which is the
    /// one users cannot see coming: macOS compiles each model for the Neural
    /// Engine, measured at 11 s for `base.en` and 141–187 s for
    /// `large-v3-turbo`, and a user who quits partway keeps none of it. The
    /// row is the only place that lands before the decision is made.
    @Test("the caption names all three costs of a pick")
    func restartCaption() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared, currentID: "whisper-base.en",
            downloaded: { _ in true }, formatterDownloaded: true)
        #expect(model.caption.contains("applies on restart"))
        #expect(model.caption.contains("downloads if not on disk"))
        #expect(model.caption.contains("Neural Engine"))
        // The wording the whole codebase agreed on: the compile recurs with
        // each macOS build, so "one time" would be a promise it cannot keep.
        #expect(model.caption.contains("once per macOS version"))
        #expect(!model.caption.contains("one time"))
    }

    @Test("a downloaded formatting model is stated, not offered")
    func formatterDownloaded() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared, currentID: "whisper-base.en",
            downloaded: { _ in true }, formatterDownloaded: true)
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
            downloaded: { _ in true }, formatterDownloaded: false)
        #expect(model.formatter.title
                == "Download formatting model… (900 MB, applies on restart)")
        #expect(model.formatter.offersDownload)
    }

    /// The model the daemon is *running* is on disk by construction — the
    /// warm-up fetched it. A row that both carries the check and threatens a
    /// download would be self-contradictory, so the presence answer is asked
    /// per model rather than assumed from the check.
    @Test("the running model reads as on disk")
    func runningModelIsOnDisk() {
        let model = ModelMenuModel.compute(
            models: ModelRegistry.shared, currentID: "whisper-base.en",
            downloaded: { $0.id == "whisper-base.en" },
            formatterDownloaded: true)
        let running = model.items.first { $0.checked }
        #expect(running?.title.hasSuffix("· on disk") == true)
    }
}
