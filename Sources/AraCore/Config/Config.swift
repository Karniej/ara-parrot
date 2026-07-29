import Foundation

public enum Engine: String, Codable, Sendable {
    case local, cloud, rules, off
}

public struct CloudConfig: Codable, Sendable {
    public var provider: String = "anthropic"
    public var model: String = "claude-opus-5"
    public var keychainAccount: String = "ara-cloud"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, model, keychainAccount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "anthropic"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "claude-opus-5"
        keychainAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount) ?? "ara-cloud"
    }
}

/// User configuration. Every field is optional on disk; absent keys keep their
/// default, so a partial or malformed file degrades to a working default rather
/// than failing startup.
///
/// Degrading is never silent. A file that cannot be read, a value that cannot be
/// decoded, and a value that decodes but is out of range each produce one line
/// on stderr naming the file and the reason. The alternative — the original
/// `try?` — meant a single typo (`"engine": "clod"`) discarded the whole file,
/// including a valid `cloud` section, with no output at all, while the same typo
/// in `mode` got a loud warning. The user cannot tell "my config is being
/// ignored" from "my config is being honoured" without one.
public struct Config: Codable, Sendable {
    public var engine: Engine = .local
    public var timeoutMs: Int = 2500
    public var mode: String = "default"
    public var hotkey: String?
    public var model: String?
    public var cloud: CloudConfig?

    public init() {}

    /// The floor `timeoutMs` is clamped to.
    ///
    /// `FormatterChain` turns `timeoutMs` into a `Duration` and races every
    /// engine against it, so `0` or a negative value makes the timer task win
    /// unconditionally: every LLM engine "times out" instantly and every
    /// dictation silently falls through to the rule-based floor. That is
    /// indistinguishable from a broken model, which is exactly the state the
    /// fall-through logging exists to make debuggable.
    ///
    /// 50ms rather than something realistic (a real on-device generation is
    /// hundreds of milliseconds at best) because the floor's job is to reject
    /// nonsense, not to overrule a deliberately tight value: `timeoutMs: 50`
    /// remains a usable way to force the timeout path by hand, which the manual
    /// checklist does in step 4b.
    public static let minimumTimeoutMs = 50

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ara/config.json")
    }

    /// Loads the config, warning about anything it had to ignore.
    ///
    /// Never throws and never exits: a daemon that refuses to start because a
    /// config file has a typo in it is worse than one that starts on defaults
    /// and says so. `warn` is injectable so the tests can assert on what a user
    /// would actually be told, rather than only on the returned value — the
    /// silence *is* the defect being fixed here.
    public static func load(from url: URL? = nil,
                            warn: (String) -> Void = Config.warnToStderr) -> Config {
        let target = url ?? defaultURL
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            // A missing file is the normal case for a default install and says
            // nothing. Anything else — unreadable permissions, a directory
            // where a file should be — is worth a line.
            if FileManager.default.fileExists(atPath: target.path) {
                warn("cannot read \(target.path) (\(type(of: error))); using defaults")
            }
            return Config()
        }

        var config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            warn("ignoring \(target.path): \(describe(error)); using defaults")
            return Config()
        }

        if config.timeoutMs < minimumTimeoutMs {
            warn("timeoutMs \(config.timeoutMs) in \(target.path) is below the "
                 + "\(minimumTimeoutMs)ms minimum — using \(minimumTimeoutMs). "
                 + "A value at or below zero disables LLM formatting entirely.")
            config.timeoutMs = minimumTimeoutMs
        }
        return config
    }

    /// Renders a decoding failure as one line the user can act on.
    ///
    /// `DecodingError`'s own description names the offending key and what was
    /// wrong with it, which is the whole point; anything else is reduced to its
    /// type name, following `CloudFormatter.translate`'s rule that a foreign
    /// error's message is a channel its producer controls.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "\(type(of: error))" }
        let (context, what): (DecodingError.Context, String) = {
            switch error {
            case .dataCorrupted(let c): return (c, "invalid value")
            case .keyNotFound(let key, let c): return (c, "missing key \(key.stringValue)")
            case .typeMismatch(let type, let c): return (c, "expected \(type)")
            case .valueNotFound(let type, let c): return (c, "no value for \(type)")
            @unknown default: return (DecodingError.Context(codingPath: [], debugDescription: ""),
                                      "undecodable")
            }
        }()
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let location = path.isEmpty ? "" : "at \(path): "
        let detail = context.debugDescription.isEmpty ? what : context.debugDescription
        return location + detail
    }

    public static let warnToStderr: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data("config: \(message)\n".utf8))
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
