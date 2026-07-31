import Foundation
import Testing
@testable import AraCore

/// The "is this model actually on disk?" rule, which both model kinds share:
/// a hub download is present when its `config.json` *and* its weights are
/// there. Driven against real temporary directories rather than the user's
/// hub cache — the point of the rule is what it says about a *partial*
/// download, and a test that needs 1.5 GB to reach that case is a test nobody
/// runs.
@Suite("Local model directory")
struct LocalModelDirectoryTests {
    /// Builds a directory with the named entries in it (files, empty).
    private func directory(_ entries: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ara-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(entry).path, contents: Data())
        }
        return root
    }

    @Test("config plus weights is present")
    func configAndWeights() throws {
        let dir = try directory(["config.json", "model.safetensors"])
        #expect(LocalModelDirectory.isPresent(dir) { entries in
            entries.contains { $0.hasSuffix(".safetensors") }
        })
    }

    /// The case the rule exists for: an interrupted download leaves the
    /// directory and the small JSON files behind. "The folder exists" would
    /// send the warm-up into a load that fails with a tokenizer-shaped error
    /// instead of an honest "not downloaded".
    @Test("config without weights is not present")
    func configWithoutWeights() throws {
        let dir = try directory(["config.json", "generation_config.json"])
        #expect(!LocalModelDirectory.isPresent(dir) { entries in
            entries.contains { $0.hasSuffix(".safetensors") }
        })
    }

    @Test("weights without a config is not present")
    func weightsWithoutConfig() throws {
        let dir = try directory(["model.safetensors"])
        #expect(!LocalModelDirectory.isPresent(dir) { entries in
            entries.contains { $0.hasSuffix(".safetensors") }
        })
    }

    @Test("a directory that does not exist is not present")
    func missingDirectory() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ara-model-absent-\(UUID().uuidString)")
        #expect(!LocalModelDirectory.isPresent(dir) { _ in true })
    }

    /// WhisperKit opens three compiled Core ML models by name and throws if
    /// any is missing, so all three are the weights question for a Whisper
    /// variant — not "at least one .mlmodelc".
    @Test("a Whisper variant needs all three compiled models")
    func whisperNeedsEveryModel() throws {
        let complete = try directory(["config.json", "MelSpectrogram.mlmodelc",
                                      "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"])
        #expect(WhisperModelStore.isPresent(in: complete))

        let partial = try directory(["config.json", "MelSpectrogram.mlmodelc",
                                     "AudioEncoder.mlmodelc"])
        #expect(!WhisperModelStore.isPresent(in: partial))
    }

    /// `TextDecoderContextPrefill.mlmodelc` is loaded only when it is there
    /// (`WhisperKit.loadModels`), so a variant that ships without one — like
    /// base.en — must not be reported missing.
    @Test("the optional prefill model is not required")
    func prefillIsOptional() throws {
        let dir = try directory(["config.json", "MelSpectrogram.mlmodelc",
                                 "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"])
        #expect(WhisperModelStore.isPresent(in: dir))
    }

    /// The directory is derived from the same hub cache and the same variant
    /// folder name WhisperKit's own downloader writes into — if these two ever
    /// disagree the menu reports "not downloaded" for a model that is right
    /// there.
    @Test("a variant lands under the whisperkit repo, named by its engine id")
    func directoryLayout() {
        let model = TranscriptionModel(
            id: "whisper-base.en", displayName: "Whisper Base",
            engine: .whisperKit, whisperKitID: "openai_whisper-base.en",
            sizeMB: 145, languages: ["en"], recommended: true)
        let path = WhisperModelStore.directory(for: model)?.path
        #expect(path?.hasSuffix(
            "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base.en") == true)
    }

    @Test("a model with no engine id has nowhere on disk to be")
    func noEngineID() {
        let model = TranscriptionModel(
            id: "someday", displayName: "Someday", engine: .parakeet,
            whisperKitID: nil, sizeMB: 1, languages: ["en"], recommended: false)
        #expect(WhisperModelStore.directory(for: model) == nil)
        #expect(!WhisperModelStore.isPresent(model))
    }
}

/// Sizes are quoted to set an expectation before a wait, so they are rendered
/// in the unit the user thinks in: nobody reads "1620 MB" as "this will take a
/// minute and a half".
@Suite("Model size label")
struct ModelSizeTests {
    @Test("megabytes below a gigabyte stay megabytes")
    func megabytes() {
        #expect(ModelSize.label(megabytes: 145) == "145 MB")
        #expect(ModelSize.label(megabytes: 900) == "900 MB")
        #expect(ModelSize.label(megabytes: 1023) == "1023 MB")
    }

    @Test("a gigabyte and up is a gigabyte, to one decimal")
    func gigabytes() {
        #expect(ModelSize.label(megabytes: 1024) == "1.0 GB")
        #expect(ModelSize.label(megabytes: 1620) == "1.6 GB")
        #expect(ModelSize.label(megabytes: 4096) == "4.0 GB")
    }

    @Test("a nonsense size renders as zero rather than as a minus sign")
    func negative() {
        #expect(ModelSize.label(megabytes: -1) == "0 MB")
        #expect(ModelSize.label(megabytes: 0) == "0 MB")
    }
}
