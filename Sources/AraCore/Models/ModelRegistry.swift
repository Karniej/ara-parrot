import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
public enum ModelRegistry {
    /// Two models, and both multilingual.
    ///
    /// ## Why two
    ///
    /// The list used to carry `whisper-base.en` and `whisper-small.en`
    /// alongside the large model. Three sizes is a choice a user has to make
    /// about a trade-off they cannot see the terms of, and the small end of it
    /// stopped being interesting once the warm-up ladder existed: the reason to
    /// pick a tiny model was that a big one took minutes to become usable, and
    /// that is now handled without asking anyone.
    ///
    /// ## Why neither is `.en`
    ///
    /// Both dropped models were English-only. Choosing one silently turned off
    /// language detection — `LanguagePlan` collapses every setting to English
    /// and warns — which is a strange thing to hand someone whose second
    /// language is why they installed a dictation tool. The multilingual small
    /// is the same weights' bigger sibling and costs the same 488 MB the `.en`
    /// small did.
    ///
    /// The English-only handling in `LanguagePlan` and `LanguageMenuModel`
    /// stays. Nothing here can select it any more, but it is the correct
    /// behaviour for a model that cannot produce other languages, and the day
    /// one is added back it should still be right.
    public static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-small",
            displayName: "Whisper Small",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small",
            sizeMB: 488,
            languages: ["multi"],
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
