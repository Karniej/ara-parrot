import Foundation
import Hub

/// Whether a model downloaded from the HuggingFace hub is actually on disk.
///
/// Generalised out of `MLXModel.isPresent`, which asked this first and for the
/// same reason: **an interrupted download leaves the directory behind**, often
/// with the small JSON files already in it. "The folder exists" would send a
/// warm-up into a load that fails with a tokenizer- or Core ML-shaped error
/// instead of the one sentence that says the model is not downloaded.
///
/// So the rule is: the repo's `config.json` — which every model kind here has
/// — *plus* whatever counts as weights for that kind, which is the one thing
/// the caller has to answer.
public enum LocalModelDirectory {
    /// - Parameter weights: given the directory's top-level entry names,
    ///   whether the weights the loader will open are among them.
    static func isPresent(_ directory: URL,
                          fileManager: FileManager = .default,
                          weights: ([String]) -> Bool) -> Bool {
        let config = directory.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: config.path) else { return false }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return weights(entries)
    }
}

/// Where WhisperKit's transcription weights land, and whether a given model's
/// are there.
///
/// The layout is not ours to choose: `WhisperKit.download` snapshots
/// `argmaxinc/whisperkit-coreml` into the shared hub cache and then addresses
/// the variant's own folder inside it, named by the engine id. This mirrors
/// that, and a test pins the path — if the two ever drift, the menu reports
/// "1.6 GB download" for a model that is already sitting on disk.
public enum WhisperModelStore {
    /// WhisperKit's default model repo (`WhisperKit.download`'s `from:`).
    static let repo = "argmaxinc/whisperkit-coreml"

    /// The compiled Core ML models `WhisperKit.loadModels` opens by name and
    /// throws over when missing. `TextDecoderContextPrefill.mlmodelc` is
    /// deliberately absent from the list: that one is loaded only when it
    /// happens to be there, and base.en ships without it.
    static let requiredModels = [
        "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
    ]

    /// The same hub cache `MLXModel` uses — `~/Documents/huggingface` by
    /// default. `nil` for a model with no engine id: there is no download for
    /// it to be, and `warmUp` throws `missingEngineID` rather than fetching
    /// anything.
    public static func directory(for model: TranscriptionModel) -> URL? {
        guard let whisperKitID = model.whisperKitID else { return nil }
        return HubApi.shared
            .localRepoLocation(Hub.Repo(id: repo, type: .models))
            .appendingPathComponent(whisperKitID)
    }

    public static func isPresent(_ model: TranscriptionModel) -> Bool {
        guard let directory = directory(for: model) else { return false }
        return isPresent(in: directory)
    }

    static func isPresent(in directory: URL, fileManager: FileManager = .default) -> Bool {
        LocalModelDirectory.isPresent(directory, fileManager: fileManager) { entries in
            requiredModels.allSatisfy(entries.contains)
        }
    }
}

/// A model's footprint, in the unit a user thinks in.
///
/// `TranscriptionModel.sizeMB` is megabytes because the registry is written in
/// them, but "1620 MB" is not a number anyone converts while deciding whether
/// to wait — and the whole reason a size is quoted at all is to set the
/// expectation before the wait rather than during it.
public enum ModelSize {
    public static func label(megabytes: Int) -> String {
        let mb = max(0, megabytes)
        guard mb >= 1024 else { return "\(mb) MB" }
        return String(format: "%.1f GB", Double(mb) / 1024)
    }

    /// The size as an answer to "what does picking this cost me?" — a
    /// footprint when the model is already here, a download when it is not.
    /// One phrase, used by both the Model submenu and `ara models list`, so a
    /// user cannot read two different stories about the same model.
    public static func availability(megabytes: Int, downloaded: Bool) -> String {
        downloaded
            ? "\(label(megabytes: megabytes)) · on disk"
            : "\(label(megabytes: megabytes)) download"
    }
}
