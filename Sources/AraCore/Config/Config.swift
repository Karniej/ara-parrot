import Foundation

public enum Engine: String, Codable, Sendable {
    case local, cloud, rules, off
}

public struct CloudConfig: Codable, Sendable {
    public var provider: String = "anthropic"
    public var model: String = "claude-opus-5"
    public var keychainAccount: String = "ara-cloud"
}

/// User configuration. Every field is optional on disk; absent keys keep their
/// default, so a partial or malformed file degrades to a working default rather
/// than failing startup.
public struct Config: Codable, Sendable {
    public var engine: Engine = .local
    public var timeoutMs: Int = 2500
    public var mode: String = "default"
    public var hotkey: String?
    public var model: String?
    public var cloud: CloudConfig?

    public init() {}

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ara/config.json")
    }

    public static func load(from url: URL? = nil) -> Config {
        let target = url ?? defaultURL
        guard let data = try? Data(contentsOf: target),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return decoded
    }

    private enum CodingKeys: String, CodingKey {
        case engine, timeoutMs, mode, hotkey, model, cloud
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .local
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 2500
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "default"
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        cloud = try c.decodeIfPresent(CloudConfig.self, forKey: .cloud)
    }
}
