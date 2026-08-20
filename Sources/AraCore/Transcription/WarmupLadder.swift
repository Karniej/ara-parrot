import Foundation

/// When the daemon should dictate on a small model while the chosen one is
/// still loading, and what may replace what once both are in flight.
///
/// ## Why there is a ladder at all
///
/// `whisper-large-v3-turbo` is the model a user who wants accuracy picks, and
/// on a cold start it is a 1.6 GB download followed by a Core ML
/// specialisation measured at 141–187 s on an M3 Pro (`WhisperWarmupPlan`).
/// The daemon explains that wait carefully — the phase, the percentage, the
/// warning that quitting starts the compile over — and explaining a
/// three-minute wait is not the same as not having one.
///
/// Nothing requires the *first* model loaded to be the *chosen* one.
/// `whisper-base` loads in a fraction of the time and transcribes well enough
/// to be useful, so it serves until the chosen model lands and then gets out of
/// the way. The swap is `WhisperKitTranscriber.adopt`, which a live model pick
/// already uses; this type is only the decisions around it.
///
/// ## Why every rule is here and not in `Ara.run`
///
/// The two loads race, and either may return first. That concurrency is not
/// reachable from a test, so nothing that *decides* anything lives in it —
/// the same split `WhisperWarmupPlan` and the `*MenuModel` types are built on.
public enum WarmupLadder {
    /// How long the chosen model gets on its own before the bootstrap starts
    /// alongside it.
    ///
    /// ## Why a delay rather than a check
    ///
    /// The ladder should not run when the chosen model is already warm: a
    /// second model load nobody waits for is pure waste. But "already warm"
    /// cannot be tested directly. A missing download is easy
    /// (`WhisperModelStore.isPresent`); the multi-minute case is a missing
    /// Neural Engine specialisation, cached under
    /// `~/Library/Caches/<client>/com.apple.e5rt.e5bundlecache/<macOS build>/…`
    /// and keyed on the signing identity, the OS build and the model. Probing
    /// that means reimplementing a private cache layout, and a wrong answer
    /// gives the worst outcome available — a three-minute wait with the ladder
    /// switched off.
    ///
    /// So the ladder measures instead of guessing. A warm load returns inside
    /// this window and the bootstrap never starts; a cold one does not, and it
    /// does.
    ///
    /// ## Where five seconds comes from
    ///
    /// Measured on an M3 Pro through the daemon's own path —
    /// `WhisperKit(config)` with `prewarm: false`, which is what
    /// `WhisperKitTranscriber.load` uses and is *not* the `loadModels()` row in
    /// `WhisperWarmupPlan`'s table:
    ///
    /// | load                                    | seconds |
    /// |-----------------------------------------|---------|
    /// | large-v3-turbo, warm and specialised    | 2.45    |
    /// | whisper-base, warm and specialised      | 0.47    |
    /// | whisper-base, first specialisation      | 2.4     |
    /// | large-v3-turbo, first specialisation    | 149     |
    ///
    /// Five seconds clears the slowest warm load with margin for a machine
    /// that is busy doing something else, and it is 3% of the wait it exists to
    /// shorten. The two errors are not symmetric, which is why the margin is
    /// generous: too long costs a cold start a few extra seconds it was going
    /// to spend anyway, while too short starts a stand-in load nobody needs.
    /// Even that is cheap — `LadderState.claimBootstrap` discards a stand-in
    /// that lost the race rather than adopting it — but it is waste, and the
    /// margin costs nothing to have.
    public static let bootstrapDelay: Duration = .seconds(5)

    /// The model to dictate on while `target` loads, or `nil` when there is
    /// nothing to gain.
    ///
    /// `ModelRegistry.bootstrap` is multilingual on purpose and that is not
    /// negotiable here: the registry's other small models are `.en` weights,
    /// and standing one of those in for a multilingual model would transcribe
    /// a Polish user's first minute as English nonsense — breaking exactly the
    /// users `LanguagePolicy` and the Language submenu exist for.
    ///
    /// `nil` for a model no larger than the bootstrap. A second load of the
    /// same size buys nothing, and on a first run it costs a download to buy
    /// it.
    public static func bootstrap(for target: TranscriptionModel) -> TranscriptionModel? {
        let bootstrap = ModelRegistry.bootstrap
        guard target.id != bootstrap.id else { return nil }
        guard target.sizeMB > bootstrap.sizeMB else { return nil }
        return bootstrap
    }

    /// Whether a bootstrap pipeline that has just finished loading may be
    /// adopted.
    ///
    /// The race this exists for: the chosen model landed first and the
    /// bootstrap's load returns a moment later. Adopting it then would swap a
    /// good model out for a worse one and leave it there — a downgrade the user
    /// never asked for and has no way to undo except by picking their own model
    /// again.
    public static func adoptsBootstrap(targetLanded: Bool) -> Bool {
        !targetLanded
    }

    /// Whether a failed warm-up should end the process.
    ///
    /// Before the ladder this was simply "the transcriber failed": a daemon
    /// that cannot transcribe is not a daemon, and exiting is more honest than
    /// sitting in the menu bar. That is still true when nothing is serving.
    ///
    /// It stops being true the moment the bootstrap is live. The user has
    /// working dictation; killing the process would take it away to punish a
    /// failure that cost them nothing. A chosen-model failure with the
    /// bootstrap serving is reported the way a failed *live* model switch
    /// already is — a stderr line and `ModelSwitch.failed` in the menu.
    public static func isFatal(targetFailed: Bool, bootstrapServing: Bool) -> Bool {
        targetFailed && !bootstrapServing
    }

    /// The one line the overlay shows on the first press while the bootstrap
    /// is serving.
    ///
    /// It answers one question and stops: "why is this transcript worse than
    /// usual?" It does not tell the user to wait, because there is nothing for
    /// them to do and the dictation they just started is not affected by
    /// knowing. The menu bar carries the rest — `ModelLabel.text` already
    /// renders `model: whisper-base → loading whisper-large-v3-turbo…`.
    public static func servingNote(target: TranscriptionModel) -> String {
        "fast model · \(target.id) still loading"
    }
}
