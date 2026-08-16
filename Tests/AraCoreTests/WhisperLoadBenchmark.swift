import Foundation
import Testing
import WhisperKit
@testable import AraCore

/// Where the seconds between "ara starts" and "dictation works" actually go.
///
/// **Opt-in**: it loads real Core ML models — up to 1.5 GB of them — several
/// times over, so it is inert unless `ARA_WHISPER_LOAD_BENCH=1` is set. Run it
/// with
///
/// ```
/// ARA_WHISPER_LOAD_BENCH=1 swift test --filter WhisperLoad
/// ```
///
/// after the model is downloaded. `ARA_WHISPER_LOAD_MODEL` picks the model id
/// (default `whisper-large-v3-turbo`).
@Suite("WhisperLoad", .serialized)
struct WhisperLoadBenchmark {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ARA_WHISPER_LOAD_BENCH"] == "1"
    }

    /// `ModelRegistry.find` deliberately does not resolve the warm-up ladder's
    /// stand-in model — nothing a user can type should select it — but the
    /// numbers this benchmark produces are the reason the ladder exists, so it
    /// has to be measurable alongside the models it stands in for.
    static var model: TranscriptionModel {
        let id = ProcessInfo.processInfo.environment["ARA_WHISPER_LOAD_MODEL"]
            ?? "whisper-large-v3-turbo"
        if id == ModelRegistry.bootstrap.id { return ModelRegistry.bootstrap }
        return ModelRegistry.find(id)!
    }

    static func ms(_ d: Duration) -> String {
        String(format: "%8.0f", Double(d.components.attoseconds) / 1e15
            + Double(d.components.seconds) * 1000)
    }

    static func line(_ label: String, _ d: Duration) {
        print("  \(Self.ms(d)) ms  \(label)")
    }

    /// Three seconds of quiet speech-shaped noise: enough to make the first
    /// transcription do a real encoder + decoder pass without depending on an
    /// audio fixture being in the repository.
    static func audio(seconds: Double = 3) -> [Float] {
        let n = Int(16000 * seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / 16000
            out[i] = Float(0.05 * sin(2 * .pi * 180 * t) * sin(2 * .pi * 3 * t))
        }
        return out
    }

    /// The Neural Engine bundle cache **for this process**, which is the only
    /// one that says anything about this run.
    ///
    /// It is emphatically *not*
    /// `~/Library/Caches/com.apple.e5rt.e5bundlecache`. That path is macOS 15's
    /// and reads 0 bytes on macOS 26 however much compiling happens — it is the
    /// measurement that sent this investigation the wrong way for an afternoon.
    /// On macOS 26 the cache is per client, under the calling process's own
    /// caches directory, keyed by OS build:
    ///
    ///     ~/Library/Caches/<client>/com.apple.e5rt.e5bundlecache/<build>/…
    ///
    /// `.cachesDirectory` resolves to exactly the `<client>` whose compiles
    /// this run is paying for, so growth here is this run's specialisation and
    /// nobody else's.
    static func cacheSize() -> (bytes: Int, files: Int) {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
        else { return (0, 0) }
        let root = caches.appendingPathComponent("com.apple.e5rt.e5bundlecache")
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return (0, 0) }
        var bytes = 0
        var files = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                files += 1
                bytes += v?.fileSize ?? 0
            }
        }
        return (bytes, files)
    }

    // MARK: - The phase split

    @Test("phases: download check, prewarm, load — twice in one process")
    func phases() async throws {
        guard Self.enabled else { return }
        let model = Self.model
        try #require(WhisperModelStore.isPresent(model), "download \(model.id) first")
        let variant = model.whisperKitID!

        print("\n=== \(model.id) — phase split, two loads in one process ===")
        let before = Self.cacheSize()
        print("  e5bundlecache before: \(before.bytes) bytes in \(before.files) files")

        for round in 1...2 {
            print("--- round \(round) ---")
            let t0 = ContinuousClock.now
            let folder = try await WhisperKit.download(variant: variant)
            let download = ContinuousClock.now - t0
            Self.line("download check (warm cache)", download)

            let t1 = ContinuousClock.now
            let config = WhisperKitConfig(model: variant, modelFolder: folder.path,
                                          verbose: false, prewarm: false, load: false,
                                          download: false)
            let kit = try await WhisperKit(config)
            let construct = ContinuousClock.now - t1
            Self.line("WhisperKit(config) with prewarm:false load:false", construct)

            let t2 = ContinuousClock.now
            try await kit.prewarmModels()
            let prewarm = ContinuousClock.now - t2
            Self.line("prewarmModels()", prewarm)
            print("      encoder specialization: "
                + "\(String(format: "%.2f", kit.currentTimings.encoderSpecializationTime))s"
                + ", decoder specialization: "
                + "\(String(format: "%.2f", kit.currentTimings.decoderSpecializationTime))s")

            let t3 = ContinuousClock.now
            try await kit.loadModels()
            let load = ContinuousClock.now - t3
            Self.line("loadModels()", load)
            print("      encoder load: "
                + "\(String(format: "%.2f", kit.currentTimings.encoderLoadTime))s"
                + ", decoder load: "
                + "\(String(format: "%.2f", kit.currentTimings.decoderLoadTime))s")

            Self.line("TOTAL (prewarm + load, today's config)",
                      download + construct + prewarm + load)

            let t4 = ContinuousClock.now
            _ = try await kit.transcribe(audioArray: Self.audio())
            Self.line("first transcription after prewarm+load", ContinuousClock.now - t4)

            let t5 = ContinuousClock.now
            _ = try await kit.transcribe(audioArray: Self.audio())
            Self.line("second transcription", ContinuousClock.now - t5)
        }

        let after = Self.cacheSize()
        print("  e5bundlecache after:  \(after.bytes) bytes in \(after.files) files")
    }

    // MARK: - prewarm:false

    @Test("load only, no prewarm — and what the first transcription then costs")
    func loadWithoutPrewarm() async throws {
        guard Self.enabled else { return }
        let model = Self.model
        try #require(WhisperModelStore.isPresent(model), "download \(model.id) first")
        let variant = model.whisperKitID!

        print("\n=== \(model.id) — prewarm:false ===")
        let t0 = ContinuousClock.now
        let folder = try await WhisperKit.download(variant: variant)
        Self.line("download check (warm cache)", ContinuousClock.now - t0)

        let t1 = ContinuousClock.now
        let config = WhisperKitConfig(model: variant, modelFolder: folder.path,
                                      verbose: false, prewarm: false, load: true,
                                      download: false)
        let kit = try await WhisperKit(config)
        let load = ContinuousClock.now - t1
        Self.line("WhisperKit(config) prewarm:false load:true", load)
        print("      encoder load: "
            + "\(String(format: "%.2f", kit.currentTimings.encoderLoadTime))s"
            + ", decoder load: "
            + "\(String(format: "%.2f", kit.currentTimings.decoderLoadTime))s")

        let t2 = ContinuousClock.now
        _ = try await kit.transcribe(audioArray: Self.audio())
        let first = ContinuousClock.now - t2
        Self.line("first transcription", first)
        Self.line("TOTAL to first transcript", load + first)

        let t3 = ContinuousClock.now
        _ = try await kit.transcribe(audioArray: Self.audio())
        Self.line("second transcription", ContinuousClock.now - t3)
    }

    // MARK: - today's config, end to end

    @Test("today's config verbatim, through the transcriber")
    func todaysConfig() async throws {
        guard Self.enabled else { return }
        let model = Self.model
        try #require(WhisperModelStore.isPresent(model), "download \(model.id) first")

        print("\n=== \(model.id) — WhisperKitTranscriber.warmUp as shipped ===")
        let transcriber = WhisperKitTranscriber(model: model)
        let t0 = ContinuousClock.now
        try await transcriber.warmUp()
        let warm = ContinuousClock.now - t0
        Self.line("warmUp()", warm)

        let t1 = ContinuousClock.now
        _ = try await transcriber.transcribe(Self.audio())
        Self.line("first transcribe()", ContinuousClock.now - t1)
    }

    // MARK: - the compute unit the specialisation is for

    /// The encoder off the Neural Engine and onto the GPU.
    ///
    /// The 2–3 minute wait a new client identity pays is the ANE compile of the
    /// audio encoder, and `.cpuAndGPU` is the one config change that does not
    /// ask for one. What it costs is what this measures: the GPU has to do the
    /// encoder pass on every utterance instead.
    @Test("audio encoder on the GPU instead of the Neural Engine")
    func encoderOnGPU() async throws {
        guard Self.enabled else { return }
        let model = Self.model
        try #require(WhisperModelStore.isPresent(model), "download \(model.id) first")
        let variant = model.whisperKitID!

        print("\n=== \(model.id) — audioEncoderCompute: .cpuAndGPU ===")
        let folder = WhisperModelStore.directory(for: model)!
        let t1 = ContinuousClock.now
        let config = WhisperKitConfig(
            model: variant, modelFolder: folder.path,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU),
            verbose: false, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        Self.line("WhisperKit(config) prewarm:false load:true", ContinuousClock.now - t1)
        print("      encoder load: "
            + "\(String(format: "%.2f", kit.currentTimings.encoderLoadTime))s"
            + ", decoder load: "
            + "\(String(format: "%.2f", kit.currentTimings.decoderLoadTime))s")

        for round in 1...3 {
            let t = ContinuousClock.now
            _ = try await kit.transcribe(audioArray: Self.audio())
            Self.line("transcription \(round)", ContinuousClock.now - t)
        }
    }
}

