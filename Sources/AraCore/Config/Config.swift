import Foundation

/// Which formatting engine `FormatterChain` prefers.
///
/// `mlx` is the default because it is the only one that works on a stock Apple
/// Silicon Mac: `apple` needs macOS 26 with Apple Intelligence switched on, and
/// `cloud` needs an API key and a network.
///
/// `apple` was called `local` until the bundled MLX engine arrived, at which
/// point "local" described two of the three engines and identified neither. The
/// decoder below still accepts the old spelling.
public enum Engine: String, Codable, Sendable, CaseIterable {
    case mlx, apple, cloud, rules, off

    /// The name this engine had in a config file written before the rename, or
    /// `nil` when it never had another name.
    static func legacyName(_ raw: String) -> Engine? {
        raw == "local" ? .apple : nil
    }

    /// Hand-written so `"local"` keeps working.
    ///
    /// This matters more than a compatibility gesture usually would:
    /// `Config.load` discards the **whole file** when any value fails to
    /// decode, so an existing `{"engine": "local", "cloud": {...}}` would lose
    /// its cloud section too, and silently switch the user to a different
    /// engine than either name means.
    ///
    /// An unrecognised value still throws, with the offending string in the
    /// message — `Config.load` renders that into the one line that tells the
    /// user their file is being ignored and why.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let engine = Engine(rawValue: raw) ?? Engine.legacyName(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize Engine from invalid String value \(raw)")
        }
        self = engine
    }
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
    public var engine: Engine = .mlx
    public var timeoutMs: Int = 2500
    public var mode: String = "default"
    public var hotkey: String?
    public var model: String?
    public var cloud: CloudConfig?

    /// Core Audio UID of the preferred input device, or `nil` for the system
    /// default. A UID rather than a name or numeric ID because it is the one
    /// identifier that survives replug and reboot; `MicrophoneStore` resolves
    /// it against the connected devices and falls back when it is absent.
    public var microphone: String?

    /// How transcripts are delivered: `"auto"`, `"type"`, or `"paste"`. Kept
    /// as the raw string and parsed in `StartupResolution.injection`, the
    /// same lenient shape as `hotkey`: a typo here warns and falls back to
    /// `auto` rather than discarding the whole file.
    public var inject: String?

    /// Milliseconds the paste path waits before restoring the user's
    /// pasteboard — see `PasteInjector.settleDelay`. Clamped on load.
    public var pasteRestoreMs: Int = 300
    /// How aggressively dictation is edited — see `CleanupIntensity`. Medium
    /// is today's behaviour, so an absent key changes nothing for anyone.
    ///
    /// Decoded with the `microphone` guarantee rather than the `engine` one: a
    /// typo here must not discard the whole file, because `cleanup` is a taste
    /// preference and losing a valid `cloud` section over it would turn a
    /// spelling mistake into an engine downgrade. The warning in `load` names
    /// the valid spellings.
    public var cleanup: CleanupIntensity = .medium

    /// Which language, or languages, dictation is transcribed in — see
    /// `LanguageSetting`. `automatic` when the key is absent, which is
    /// today's behaviour for an English-only model (there is nothing to
    /// detect) and the *fix* for a multilingual one: someone who chose a
    /// 1.6 GB multilingual model chose it to speak more than one language,
    /// and pinning them silently to English is the bug.
    ///
    /// Decoded with the `cleanup` guarantee, not the `engine` one: a typo in
    /// a language code must not discard the whole file — losing a valid
    /// `cloud` section over `"pll"` would turn a spelling mistake into an
    /// engine downgrade. The warning in `load` names the valid shapes.
    public var language: LanguageSetting = .automatic

    /// Set during decoding when `cleanup` was present but not one of its four
    /// spellings; `load` turns it into the warning, exactly as
    /// `microphoneProblem` below.
    var cleanupProblem: String?

    /// Set during decoding when `language` was present but not a shape
    /// `LanguageSetting` accepts; `load` turns it into the warning. Same
    /// contract as `cleanupProblem`: remembered, never rethrown.
    var languageProblem: String?

    /// Set during decoding when `microphone` was present but not a string;
    /// `load` turns it into the warning. Deferred rather than printed in
    /// `init(from:)` because the decoder does not know the file path or the
    /// caller's `warn` sink — and unlike every other key, a garbage
    /// `microphone` must not throw: throwing discards the whole file, which
    /// would turn a typo in a routing preference into losing the cloud
    /// section. Catching locally keeps the siblings.
    var microphoneProblem: String?

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

    /// The clamp on `pasteRestoreMs`, which trades two failure modes against
    /// each other. Too short and the restore races the paste itself: the
    /// target app services the synthesized ⌘V *after* the user's pasteboard is
    /// back, and pastes the wrong thing — the one bug this whole mechanism
    /// exists to prevent. Too long and the pasteboard spends seconds holding
    /// the transcript: a ⌘V of your own in that window pastes the transcript,
    /// and a ⌘C forfeits the restore (deliberately — `PasteInjector` checks
    /// the pasteboard's change count and stands down rather than clobber a
    /// copy the user just made, which also makes large values far cheaper
    /// than they would otherwise be). 50ms rejects values that lose the race
    /// unconditionally; 5000ms caps the exposure while still accommodating
    /// genuinely slow pasters (a remote-desktop session, an Electron app
    /// under load).
    public static let minimumPasteRestoreMs = 50
    public static let maximumPasteRestoreMs = 5000

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

        if let problem = config.microphoneProblem {
            warn("ignoring microphone in \(target.path): \(problem); using the default input")
            config.microphoneProblem = nil
        }
        if let problem = config.cleanupProblem {
            warn("ignoring cleanup in \(target.path): \(problem); valid values are "
                 + "\(CleanupIntensity.validNames) — using medium")
            config.cleanupProblem = nil
        }
        if let problem = config.languageProblem {
            warn("ignoring language in \(target.path): \(problem); valid values are "
                 + "\(LanguageSetting.validNames) — detecting automatically")
            config.languageProblem = nil
        }
        if config.timeoutMs < minimumTimeoutMs {
            warn("timeoutMs \(config.timeoutMs) in \(target.path) is below the "
                 + "\(minimumTimeoutMs)ms minimum — using \(minimumTimeoutMs). "
                 + "A value at or below zero disables LLM formatting entirely.")
            config.timeoutMs = minimumTimeoutMs
        }
        if config.pasteRestoreMs < minimumPasteRestoreMs {
            warn("pasteRestoreMs \(config.pasteRestoreMs) in \(target.path) is below the "
                 + "\(minimumPasteRestoreMs)ms minimum — using \(minimumPasteRestoreMs). "
                 + "A restore that fast races the paste it is waiting for.")
            config.pasteRestoreMs = minimumPasteRestoreMs
        }
        if config.pasteRestoreMs > maximumPasteRestoreMs {
            warn("pasteRestoreMs \(config.pasteRestoreMs) in \(target.path) is above the "
                 + "\(maximumPasteRestoreMs)ms maximum — using \(maximumPasteRestoreMs). "
                 + "The pasteboard holds the transcript for this long after every dictation.")
            config.pasteRestoreMs = maximumPasteRestoreMs
        }
        return config
    }

    /// Why a menu pick could not be saved. Thrown rather than warned from
    /// here because only the caller knows what "not saved" costs the user (the
    /// in-memory pick still holds until the daemon exits).
    public enum PersistError: Error, CustomStringConvertible {
        /// The file's top level is not a JSON object, so there is no place a
        /// `microphone` key could be set without discarding the user's content.
        case notAnObject(path: String)

        public var description: String {
            switch self {
            case .notAnObject(let path):
                return "\(path) is not a JSON object"
            }
        }
    }

    /// Sets or removes the `microphone` key in the config file, touching
    /// nothing else — *including keys this version of ara does not know
    /// about*. The file is read back as generic JSON, one key is changed, and
    /// the object is rewritten; decoding through `Config` and re-encoding
    /// would silently drop every field the struct has never heard of, which
    /// turns a menu click into data loss the day a newer config meets an
    /// older binary.
    ///
    /// A file that cannot be parsed is left byte-for-byte untouched and the
    /// failure is thrown: overwriting it would replace a repairable typo with
    /// our guess at the user's intent. A missing file is created only when
    /// there is a pick to record — clearing a preference that was never
    /// written needs no file.
    ///
    /// JSON guarantees keys and values, not bytes: rewriting normalizes
    /// formatting and key order. Comments could not survive, but comments
    /// were never valid in this file to begin with.
    public static func persistMicrophone(_ uid: String?, at url: URL? = nil) throws {
        try rewriteOneKey("microphone", to: uid, at: url)
    }

    /// Sets the `cleanup` key in the config file, with `persistMicrophone`'s
    /// guarantees — every other key survives, a file that cannot be parsed is
    /// left byte-for-byte untouched — because it is the same rewrite. The
    /// caller (the Cleanup submenu) owns telling the user a saved pick still
    /// applies on restart, not on the next utterance: the session's intensity
    /// is stamped when the daemon builds it.
    public static func persistCleanup(_ intensity: CleanupIntensity,
                                      at url: URL? = nil) throws {
        try rewriteOneKey("cleanup", to: intensity.rawValue, at: url)
    }

    /// Sets the `model` key, with the guarantees above — the same rewrite.
    /// The caller (the Model submenu) owns the honesty about *when* a saved
    /// pick applies: the transcriber is built around one model at startup, so
    /// the pick takes effect on the next launch, and a model not yet on disk
    /// is downloaded by that launch's warm-up.
    public static func persistModel(_ id: String?, at url: URL? = nil) throws {
        try rewriteOneKey("model", to: id, at: url)
    }

    /// Sets the `hotkey` key, with the guarantees above — the same rewrite.
    /// Takes the enum rather than a string so a menu pick cannot write a
    /// spelling `StartupResolution.hotkey` would warn about and discard.
    public static func persistHotkey(_ hotkey: Hotkey, at url: URL? = nil) throws {
        try rewriteOneKey("hotkey", to: hotkey.rawValue, at: url)
    }

    /// Sets the `engine` key, with the guarantees above — the same rewrite.
    /// The enum for `persistHotkey`'s reason: `Engine`'s decoder throws on an
    /// unknown spelling and `Config.load` then discards the whole file, so a
    /// free-string parameter here would let a menu bug disable the user's
    /// entire config.
    public static func persistEngine(_ engine: Engine, at url: URL? = nil) throws {
        try rewriteOneKey("engine", to: engine.rawValue, at: url)
    }

    /// Sets the `language` key, with the guarantees above — the same rewrite.
    /// Takes the enum rather than a string so a menu pick cannot write a
    /// spelling `Config.load` would warn about and ignore.
    ///
    /// A single monitored language is written as a plain string (`"pl"`) and
    /// a set as an array (`["en","pl"]`), which is how a person writes them
    /// by hand — the one place `rewriteOneKey` writes something other than a
    /// string, and the reason it takes `Any?`.
    public static func persistLanguage(_ setting: LanguageSetting,
                                       at url: URL? = nil) throws {
        let value: Any
        switch setting {
        case .automatic: value = LanguageSetting.automaticName
        case .monitored(let codes) where codes.count == 1: value = codes[0]
        case .monitored(let codes): value = codes
        }
        try rewriteOneKey("language", to: value, at: url)
    }

    /// The shared mechanics of the persists above: read back as generic
    /// JSON, change one key, rewrite. `nil` removes the key — and a missing
    /// file stays missing then, because clearing a preference that was never
    /// written needs no file.
    ///
    /// `Any?` rather than `String?` only because `persistLanguage` writes an
    /// array; every other caller passes a string. The value must be something
    /// `JSONSerialization` can encode, which the callers guarantee by taking
    /// enums rather than free strings.
    private static func rewriteOneKey(_ key: String, to value: Any?,
                                      at url: URL?) throws {
        let target = url ?? defaultURL

        var object: [String: Any]
        if FileManager.default.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: target)
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = parsed as? [String: Any] else {
                throw PersistError.notAnObject(path: target.path)
            }
            object = dictionary
        } else {
            guard value != nil else { return }
            object = [:]
        }

        if let value {
            object[key] = value
        } else {
            object.removeValue(forKey: key)
        }

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
    }

    /// Renders a decoding failure as one line the user can act on.
    ///
    /// `DecodingError`'s own description names the offending key and what was
    /// wrong with it, which is the whole point; anything else is reduced to its
    /// type name, following `CloudFormatter.translate`'s rule that a foreign
    /// error's message is a channel its producer controls.
    ///
    /// Internal rather than private because `LocalDictionary.load` reports
    /// its malformed file the same way, and two renderers would drift.
    static func describe(_ error: any Error) -> String {
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
        case engine, timeoutMs, mode, hotkey, model, cloud, microphone, inject, pasteRestoreMs,
             cleanup, language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .mlx
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 2500
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "default"
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        cloud = try c.decodeIfPresent(CloudConfig.self, forKey: .cloud)
        inject = try c.decodeIfPresent(String.self, forKey: .inject)
        pasteRestoreMs = try c.decodeIfPresent(Int.self, forKey: .pasteRestoreMs) ?? 300
        do {
            microphone = try c.decodeIfPresent(String.self, forKey: .microphone)
        } catch {
            // See `microphoneProblem`: unset, remembered, never rethrown.
            microphone = nil
            microphoneProblem = Config.describe(error)
        }
        do {
            cleanup = try c.decodeIfPresent(CleanupIntensity.self, forKey: .cleanup)
                ?? .medium
        } catch {
            // See `cleanupProblem`: defaulted, remembered, never rethrown.
            cleanup = .medium
            cleanupProblem = Config.describe(error)
        }
        do {
            language = try c.decodeIfPresent(LanguageSetting.self, forKey: .language)
                ?? .automatic
        } catch {
            // See `languageProblem`: defaulted, remembered, never rethrown.
            language = .automatic
            languageProblem = Config.describe(error)
        }
    }
}
