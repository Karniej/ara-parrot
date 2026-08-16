import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
public enum ModelRegistry {
    public static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
    ]

    /// The model the daemon dictates on while a larger chosen one loads — see
    /// `WarmupLadder`.
    ///
    /// **Multilingual, and that is the whole reason it is this variant.** The
    /// two small models in `shared` are `.en` weights. Standing either of them
    /// in for `whisper-large-v3-turbo` would transcribe a Polish user's first
    /// minute as English nonsense, which breaks exactly the users
    /// `LanguagePolicy` and the Language submenu were built for. This one can
    /// serve any language setting the model it stands in for can.
    ///
    /// **Deliberately outside `shared`.** That list is what the Model submenu
    /// offers, and this is a stopgap rather than a choice: listing it would let
    /// a user pick a deliberately worse model by mistake and never learn why
    /// their transcripts got worse. `find` does not resolve it either, so it
    /// can never arrive through `config.json` or a menu pick — the only thing
    /// that can select it is the ladder.
    public static let bootstrap = TranscriptionModel(
        id: "whisper-base",
        displayName: "Whisper Base (multilingual)",
        engine: .whisperKit,
        whisperKitID: "openai_whisper-base",
        sizeMB: 145,
        languages: ["multi"],
        recommended: false
    )

    /// A model the user may *choose*: the submenu's rows, `--model`, and
    /// `config.json`. `bootstrap` is deliberately not among them.
    public static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    /// A model the user may *name*, which is a wider question than what they
    /// may choose — `ara models download` should be able to pre-fetch the
    /// ladder's stand-in so a first cold start does not pay for it, and that
    /// is not the same as offering it as a transcription model.
    public static func resolve(_ id: String) -> TranscriptionModel? {
        id == bootstrap.id ? bootstrap : find(id)
    }

    public static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
