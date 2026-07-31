import Foundation

/// Where a warm-up gets the folder it loads the Core ML models out of.
public enum ModelSource: Equatable, Sendable {
    /// The variant is complete on disk. Load straight from here: no network,
    /// no hub, no seconds spent being told what we already know.
    case local(URL)
    /// Ask the hub. It downloads what is missing and re-fetches whatever no
    /// longer matches its etag, which is also the only repair path there is.
    case hub
}

/// The two decisions `WhisperKitTranscriber.warmUp` makes before it loads
/// anything, kept here because they are the whole of the change and a comment
/// is not a test.
///
/// ## Why this exists
///
/// `warmUp` used to call `WhisperKit.download` unconditionally, even when the
/// variant was demonstrably already on disk, and hand the folder it returned
/// straight back through `modelFolder`. On a warm cache that call downloads
/// nothing — it lists the repo over the network and compares etags — but it is
/// not free, and it is not fast. Measured on an M3 Pro with both variants fully
/// cached:
///
/// | variant                | hub check | rest of warm-up |
/// |------------------------|-----------|-----------------|
/// | whisper-base.en        | 3.7s      | 0.7s            |
/// | whisper-large-v3-turbo | 4.4–6.1s  | 2.8–4.5s        |
///
/// So the check was 85% of base.en's startup and around 60% of the large
/// model's — every launch, forever, to confirm that files which are already
/// there are still there. Worse, it is a network call on the path that gates
/// dictation: on a slow or captive network it does not cost four seconds, it
/// costs whatever `URLSession` decides, and the user is standing there holding
/// a hotkey that will not record.
///
/// ## What it costs to skip
///
/// `WhisperModelStore.isPresent` checks `config.json` and the three
/// `.mlmodelc` directories. It does not open a 1.3 GB `weight.bin` to see
/// whether the last byte arrived, so a download interrupted at 99% still looks
/// present. That is exactly the case the etag check used to repair — so it
/// still is repaired, by `recovery(after:)`: a local load that throws falls
/// back to the hub and tries once more. The repair moves from "every launch,
/// pre-emptively" to "the launch it is actually needed", which is the same
/// guarantee at a hundredth of the cost.
public enum WhisperWarmupPlan {
    /// How long a load may run before it is reported as something other than a
    /// load.
    ///
    /// On a warm cache the only thing that takes longer than a few seconds is
    /// Core ML compiling the model for the Neural Engine. Measured on an M3
    /// Pro, per client identity:
    ///
    /// | load                                 | seconds |
    /// |--------------------------------------|---------|
    /// | base.en, already specialised         | 0.5     |
    /// | large-v3-turbo, already specialised  | 1.0     |
    /// | base.en, first specialisation        | 11.3    |
    /// | large-v3-turbo, first specialisation | 141–187 |
    ///
    /// Twenty seconds clears every load that finishes on its own and catches
    /// the one that does not.
    public static let specialisationThreshold: Duration = .seconds(20)

    /// What to write to stderr once the threshold passes.
    ///
    /// The specialisation is all or nothing: a compile killed 75 seconds into
    /// its 145 leaves ~900 MB of intermediate behind and the next launch
    /// starts from zero — measured, and visible as the abandoned
    /// `…​.tmp.<pid>.bundle` directories under
    /// `~/Library/Caches/<client>/com.apple.e5rt.e5bundlecache/`. So the
    /// sentence has exactly one job: stop the user pressing ^C. It says the
    /// wait is finite, that it does not recur, and that quitting throws it
    /// away.
    ///
    /// ## "once per macOS version", not "one time"
    ///
    /// The cache path carries the OS build — `…/e5bundlecache/25F80/…` — so a
    /// macOS update costs the compile again. Promising a one-off would be a
    /// claim the next system update breaks, and a user who was told "one time"
    /// and then waits three minutes again has been given a reason to distrust
    /// every other thing the daemon says. (The key's other two components,
    /// the signing identity and the model, do not need saying: users do not
    /// rebuild ara, and switching models is a choice they made.)
    public static func specialisationNotice(model: String) -> String {
        "still preparing \(model) for the Neural Engine. macOS compiles each "
            + "model for this machine once per macOS version — a few minutes "
            + "for the large models — and quitting before it finishes starts "
            + "it over.\n"
    }

    /// - Parameters:
    ///   - present: `WhisperModelStore.isPresent(model)`.
    ///   - directory: `WhisperModelStore.directory(for: model)` — `nil` for a
    ///     model with no engine id, which has nowhere on disk to be.
    public static func source(present: Bool, directory: URL?) -> ModelSource {
        guard present, let directory else { return .hub }
        return .local(directory)
    }

    /// What to try after a load from `source` threw, or `nil` when there is
    /// nothing left to try and the error belongs to the caller.
    ///
    /// Exactly one step, in one direction. A hub load that failed has already
    /// re-checked every etag and re-fetched whatever did not match; running it
    /// again spends the same seconds to reach the same error, and a warm-up
    /// that retries forever is a daemon that never reports the failure it
    /// should.
    public static func recovery(after source: ModelSource) -> ModelSource? {
        switch source {
        case .local: return .hub
        case .hub: return nil
        }
    }

    /// Runs `load` against `source`, and once more against `recovery(after:)`
    /// if the first attempt threw.
    ///
    /// Generic over the result so the retry rule can be tested without a
    /// gigabyte of Core ML behind it — the thing worth pinning here is not
    /// *what* loads but that the second attempt happens, happens against the
    /// hub, and happens **once**. Get that wrong in the direction of never
    /// retrying and a user with a download truncated at 99% gets a permanent
    /// startup failure where they used to get a silent repair.
    ///
    /// When both attempts fail it is the **second** error that reaches the
    /// caller. By then the hub has been asked for the files and could not
    /// supply them, and "the download failed" is the sentence a user can act on
    /// — "the model on disk would not load" only describes the state the repair
    /// was already trying to fix. The first error is not simply dropped: it is
    /// handed to `onRepair`, which is the only place it can still be reported,
    /// and it is the answer to "why is this downloading again?".
    ///
    /// ## Cancellation is not a fault to repair
    ///
    /// A `CancellationError` means the daemon is shutting down or the warm-up
    /// was superseded. Answering it with a hub round trip would spend a user's
    /// network on work nobody is waiting for, and — because the hub call is
    /// itself cancellable — would usually just throw the same error a second
    /// time, slower. It goes straight back to the caller.
    public static func attempt<T>(
        from source: ModelSource,
        onRepair: (ModelSource, any Error) -> Void = { _, _ in },
        _ load: (ModelSource) async throws -> T
    ) async throws -> T {
        do {
            return try await load(source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let fallback = recovery(after: source) else { throw error }
            onRepair(fallback, error)
            return try await load(fallback)
        }
    }
}
