import Foundation

/// What the daemon needs of whatever is turning audio into words.
///
/// ## Why this exists now and did not before
///
/// There was one transcriber, so `Ara.run` simply held a `WhisperKitTranscriber`
/// and the tiny `Transcriber` protocol was only used by the session's tests.
/// With Parakeet there are two, chosen per model, and the daemon must not care
/// which it has for the two things it does on every utterance: hand over
/// samples, and tell it the language setting changed.
///
/// ## What is deliberately not here
///
/// `adopt(_:model:)` and `buildPipeline` — the machinery behind the warm-up
/// ladder and live model switching — stay on `WhisperKitTranscriber` and are
/// reached by a conditional cast at the two call sites that use them.
///
/// That is not squeamishness about an existential. Those methods exist because
/// a Whisper model takes minutes to become usable and something has to serve
/// utterances in the meantime; the ladder is a whole subsystem built around
/// that wait. Parakeet loads in about a third of a second (measured, on an M3
/// Pro, against Whisper's 1.5 s warm and 150 s cold), so there is nothing to
/// stand in for and nothing to swap. Hoisting the ladder into this protocol
/// would oblige every future engine to implement a solution to a problem it
/// does not have.
///
/// `Actor` rather than `AnyObject`: both implementations are actors, and the
/// isolation is the point — a transcription in flight must not race a language
/// change or a model swap.
public protocol SpeechTranscriber: Actor {
    /// Which model is *actually* serving, as opposed to what the config asks
    /// for. `nonisolated` because the menu reads it on the main actor to draw
    /// a label, and must not await a transcriber that is busy inside a load.
    nonisolated var modelID: String { get }

    /// Loads whatever the first utterance would otherwise have to wait for.
    ///
    /// - Parameter onPhase: what the warm-up is doing, for the overlay and the
    ///   setup window. Called from arbitrary threads.
    func warmUp(onPhase: @escaping @Sendable (TranscriberWarmup) -> Void) async throws

    /// The Language submenu changed. Applies to the next utterance, never the
    /// one in flight.
    func setLanguage(_ setting: LanguageSetting)

    func transcribe(_ audio: [Float]) async throws -> String
}

/// Builds the transcriber a model asks for.
///
/// One place, because the alternative is a `switch` at every construction site
/// — the daemon's startup, the live model switch, `ara models`, and the tests
/// — and a new engine then means finding all of them.
public enum TranscriberFactory {
    public static func make(model: TranscriptionModel,
                            language: LanguageSetting = .automatic) -> any SpeechTranscriber {
        switch model.engine {
        case .parakeet:
            return ParakeetTranscriber(model: model, language: language)
        case .whisperKit:
            return WhisperKitTranscriber(model: model, language: language)
        }
    }
}

/// The transcriber the daemon is currently dictating with, in a box that can
/// be swapped.
///
/// ## Why a box
///
/// The daemon builds its transcriber once and hands it to a dozen closures —
/// the hotkey handler, the menus, the warm-up task. A model switch has to
/// change what those closures talk to, and with two engines it can now change
/// the *type* as well: Whisper to Parakeet is not a new pipeline inside the
/// same actor, it is a different actor entirely.
///
/// `WhisperKitTranscriber.adopt` solved the same problem for one engine by
/// swapping a pipeline inside a fixed object. That still works and the ladder
/// still uses it — see `whisperKit` — but it cannot cross an engine boundary,
/// and this can.
///
/// ## Why the replacement warms up first
///
/// `replace(with:)` takes a transcriber that is already loaded. Loading it
/// *outside* the box is the whole point: a Whisper model can take minutes, and
/// warming it inside would serialise every utterance behind it — the same
/// reasoning that made `buildPipeline` static.
public actor ActiveTranscriber: SpeechTranscriber {
    private var current: any SpeechTranscriber

    public init(_ transcriber: any SpeechTranscriber) {
        current = transcriber
        _modelID = transcriber.modelID
    }

    /// Reads through to whatever is live. `nonisolated` for the reason the
    /// underlying ones are: the menu draws this label on the main actor and
    /// must not await a transcriber that is inside a load.
    ///
    /// The box holds `current` in a lock-free `var` that only the actor
    /// mutates, so this reads the *box's* own copy rather than the actor's —
    /// kept in step by `replace`.
    nonisolated(unsafe) private var _modelID: String = ""
    private let modelIDLock = NSLock()
    public nonisolated var modelID: String {
        modelIDLock.withLock { _modelID }
    }

    public func warmUp(
        onPhase: @escaping @Sendable (TranscriberWarmup) -> Void = { _ in }
    ) async throws {
        try await current.warmUp(onPhase: onPhase)
    }

    public func setLanguage(_ setting: LanguageSetting) {
        Task { [current] in await current.setLanguage(setting) }
    }

    public func transcribe(_ audio: [Float]) async throws -> String {
        try await current.transcribe(audio)
    }

    /// Swaps in an already-loaded transcriber. The utterance in flight, if
    /// any, finishes on the old one: this is actor-isolated, so the swap lands
    /// between two `transcribe` calls and never inside one.
    public func replace(with transcriber: any SpeechTranscriber) {
        current = transcriber
        modelIDLock.withLock { _modelID = transcriber.modelID }
    }

    /// The live transcriber when it is Whisper's, for the warm-up ladder.
    ///
    /// The ladder is Whisper-specific by nature — it exists because a Whisper
    /// model can take minutes to load — so rather than pretend otherwise
    /// through the protocol, the two call sites that need it ask for it, and
    /// get `nil` when the answer is "there is no wait to paper over".
    public var whisperKit: WhisperKitTranscriber? {
        current as? WhisperKitTranscriber
    }
}
