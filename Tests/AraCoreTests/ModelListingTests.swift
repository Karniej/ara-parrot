import Foundation
import Testing
@testable import AraCore

/// `ara models list` is where a user picks a model, and picking one that is
/// not on disk is what makes the next launch take a minute and a half. So the
/// listing says which are already here — and the rules for saying it live in
/// a pure function, not in the subcommand's `print` loop.
@Suite("Model listing")
struct ModelListingTests {
    private static func model(_ id: String, sizeMB: Int, recommended: Bool = false,
                              languages: [String] = ["en"],
                              displayName: String? = nil) -> TranscriptionModel {
        TranscriptionModel(id: id, displayName: displayName ?? id,
                           engine: .whisperKit, whisperKitID: id, sizeMB: sizeMB,
                           languages: languages, recommended: recommended)
    }

    @Test("a downloaded model is marked, a missing one is not")
    func presenceMarker() {
        let lines = ModelListing.lines(
            models: [Self.model("whisper-base.en", sizeMB: 145),
                     Self.model("whisper-large-v3-turbo", sizeMB: 1620,
                                languages: ["multi"])],
            isPresent: { $0.id == "whisper-base.en" })
        #expect(lines[0].contains("145 MB · on disk"))
        #expect(!lines[1].contains("on disk"))
    }

    /// The whole point of the column: what a pick will cost before it is made.
    @Test("a model not on disk names the download it implies")
    func downloadSize() {
        let lines = ModelListing.lines(
            models: [Self.model("whisper-large-v3-turbo", sizeMB: 1620)],
            isPresent: { _ in false })
        #expect(lines[0].contains("1.6 GB download"))
    }

    @Test("the recommended model keeps its star, and only it")
    func star() {
        let lines = ModelListing.lines(
            models: [Self.model("whisper-base.en", sizeMB: 145, recommended: true),
                     Self.model("whisper-small.en", sizeMB: 488)],
            isPresent: { _ in true })
        #expect(lines[0].hasPrefix("★ "))
        #expect(lines[1].hasPrefix("  "))
    }

    @Test("every row still carries the id, the languages and the display name")
    func rowContents() {
        let lines = ModelListing.lines(
            models: [Self.model("whisper-large-v3-turbo", sizeMB: 1620,
                                languages: ["multi"],
                                displayName: "Whisper Large v3 Turbo")],
            isPresent: { _ in true })
        #expect(lines[0].contains("whisper-large-v3-turbo"))
        #expect(lines[0].contains("[multi]"))
        #expect(lines[0].contains("Whisper Large v3 Turbo"))
    }

    @Test("one row per model, in registry order")
    func rowCount() {
        let lines = ModelListing.lines(models: ModelRegistry.shared,
                                       isPresent: { _ in false })
        #expect(lines.count == ModelRegistry.shared.count)
        #expect(zip(lines, ModelRegistry.shared).allSatisfy { $0.contains($1.id) })
    }
}
