import Foundation

/// A named output style. A mode is just a rewrite instruction plus the
/// metadata needed to pick it automatically.
public struct Mode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let prompt: String
    public let appBundleIDs: [String]
    public let usesLLM: Bool

    public init(id: String, name: String, prompt: String,
                appBundleIDs: [String], usesLLM: Bool) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.appBundleIDs = appBundleIDs
        self.usesLLM = usesLLM
    }
}
