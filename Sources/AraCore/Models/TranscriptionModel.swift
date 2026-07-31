import Foundation

enum TranscriptionEngine: String, Codable {
    case whisperKit
    case parakeet
}

public struct TranscriptionModel: Codable {
    public let id: String
    public let displayName: String
    let engine: TranscriptionEngine
    /// Engine-specific identifier (e.g. "openai_whisper-base.en" for WhisperKit).
    let whisperKitID: String?
    public let sizeMB: Int
    public let languages: [String]
    public let recommended: Bool

    /// Whether this model can only produce English — the `.en` weights, whose
    /// registry entry lists `["en"]` and nothing else. (`["multi"]` is how a
    /// multilingual model spells the other answer.)
    ///
    /// It matters because the whole language feature is meaningless here:
    /// there is no language token to pick and nothing to detect, so
    /// `LanguagePlan` collapses every setting to today's behaviour and warns
    /// rather than pretending. Written as "no language other than English" so
    /// a future `["en","en-GB"]` still classifies correctly, and an empty list
    /// — a registry defect — is treated as multilingual, which fails loudly
    /// at the decoder rather than silently as English.
    public var isEnglishOnly: Bool {
        !languages.isEmpty && !languages.contains { $0 != "en" }
    }
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
