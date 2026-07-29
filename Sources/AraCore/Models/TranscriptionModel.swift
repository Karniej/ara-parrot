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
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
