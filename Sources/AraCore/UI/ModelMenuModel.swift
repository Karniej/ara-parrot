import Foundation

/// What the Model submenu shows, computed from the model registry, the id the
/// daemon is running, and whether the local formatting model is on disk — and
/// nothing else. `MenuBarController` transcribes a model into `NSMenuItem`s
/// verbatim; every labeling rule lives here, where a unit test can reach it
/// without a screen.
public struct ModelMenuModel: Equatable, Sendable {
    /// One pickable transcription model: its id (what `persistModel` writes),
    /// its size (a pick can mean a download, so the cost sits on the row),
    /// and whether it is the model the daemon is currently running.
    public struct Item: Equatable, Sendable {
        public let title: String
        public let id: String
        public let checked: Bool
    }

    /// The formatting-model line under the picker. Informational when the
    /// model is downloaded; an offer when it is not. The offer never fetches
    /// anything in-process — 0.9 GB is a CLI action (`MLXModel` is reachable
    /// only from `ara models download-formatter`, by design), so clicking
    /// it shows the exact command instead. Honest beats magic.
    public struct FormatterItem: Equatable, Sendable {
        public let title: String
        public let offersDownload: Bool
    }

    public let items: [Item]
    public let formatter: FormatterItem

    /// The disabled line under the choices, `CleanupMenuModel`'s pattern: the
    /// transcriber is built around one model at startup, so a pick persists
    /// to the config and takes effect on the next launch — and a model not on
    /// disk is fetched by that launch's warm-up, which the caption also owns
    /// up to.
    public let caption: String

    /// The check sits on `currentID` — the model the running transcriber was
    /// built with, which `StartupResolution.model` resolved from flag, config
    /// and the recommended default.
    public static func compute(models: [TranscriptionModel],
                               currentID: String,
                               formatterDownloaded: Bool) -> ModelMenuModel {
        ModelMenuModel(
            items: models.map { model in
                Item(title: "\(model.id) · \(model.sizeMB) MB",
                     id: model.id,
                     checked: model.id == currentID)
            },
            formatter: formatterDownloaded
                ? FormatterItem(title: "Formatting model: ✓ downloaded",
                                offersDownload: false)
                : FormatterItem(
                    title: "Download formatting model… "
                        + "(\(MLXModel.sizeMB) MB, applies on restart)",
                    offersDownload: true),
            caption: "applies on restart — downloads if not on disk")
    }
}
