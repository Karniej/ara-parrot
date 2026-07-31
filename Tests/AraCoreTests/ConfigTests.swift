import Foundation
import Testing
@testable import AraCore

@Suite("Config")
struct ConfigTests {
    private func write(_ json: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-cfg-\(UUID().uuidString).json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("missing file yields defaults")
    func missingFile() {
        let cfg = Config.load(from: URL(fileURLWithPath: "/nonexistent/x.json"))
        #expect(cfg.engine == .mlx)
        #expect(cfg.timeoutMs == 2500)
        #expect(cfg.mode == "default")
    }

    @Test("partial file keeps defaults for absent keys")
    func partialFile() {
        let cfg = Config.load(from: write(#"{"engine":"rules"}"#))
        #expect(cfg.engine == .rules)
        #expect(cfg.timeoutMs == 2500)
    }

    @Test("malformed file falls back to defaults rather than crashing")
    func malformedFile() {
        let cfg = Config.load(from: write("not json at all"))
        #expect(cfg.engine == .mlx)
    }

    // MARK: - A file that is ignored says so

    /// Collects what the user would have been told.
    private final class Warnings: @unchecked Sendable {
        private(set) var lines: [String] = []
        var sink: (String) -> Void { { self.lines.append($0) } }
        var joined: String { lines.joined(separator: "\n") }
    }

    @Test("an invalid enum value warns and names the file and the key")
    func invalidEnumWarns() {
        let warnings = Warnings()
        let url = write(#"{"engine":"clod","cloud":{"model":"claude-opus-5"}}"#)
        let cfg = Config.load(from: url, warn: warnings.sink)

        // The whole file is still discarded — one bad value cannot be repaired
        // into a good config — but the user is told, which is the difference
        // between a mystery and a typo.
        #expect(cfg.engine == .mlx)
        #expect(cfg.cloud == nil)
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains(url.path))
        #expect(warnings.joined.contains("engine"))
        #expect(warnings.joined.contains("clod"))
    }

    @Test("a wrongly typed value warns and names the key")
    func typeMismatchWarns() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"timeoutMs":"2500"}"#), warn: warnings.sink)
        #expect(cfg.timeoutMs == 2500)  // the default, not the string
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains("timeoutMs"))
    }

    @Test("a syntax error warns")
    func syntaxErrorWarns() {
        let warnings = Warnings()
        _ = Config.load(from: write("{ not json"), warn: warnings.sink)
        #expect(warnings.lines.count == 1)
    }

    @Test("a missing file is silent — it is the normal case")
    func missingFileIsSilent() {
        let warnings = Warnings()
        _ = Config.load(from: URL(fileURLWithPath: "/nonexistent/x.json"),
                        warn: warnings.sink)
        #expect(warnings.lines.isEmpty)
    }

    @Test("a valid file is silent")
    func validFileIsSilent() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"engine":"rules","timeoutMs":2500}"#),
                              warn: warnings.sink)
        #expect(cfg.engine == .rules)
        #expect(warnings.lines.isEmpty)
    }

    // MARK: - timeoutMs is clamped

    @Test("a zero timeout is clamped and warned about")
    func zeroTimeoutClamped() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"timeoutMs":0}"#), warn: warnings.sink)
        // Unclamped, .milliseconds(0) makes the deadline win every race, so
        // every LLM engine "times out" instantly and formatting is silently off.
        #expect(cfg.timeoutMs == Config.minimumTimeoutMs)
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains("timeoutMs"))
    }

    @Test("a negative timeout is clamped")
    func negativeTimeoutClamped() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"timeoutMs":-1}"#), warn: warnings.sink)
        #expect(cfg.timeoutMs == Config.minimumTimeoutMs)
        #expect(warnings.lines.count == 1)
    }

    @Test("a deliberately tight but usable timeout survives")
    func tightTimeoutKept() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"timeoutMs":50}"#), warn: warnings.sink)
        #expect(cfg.timeoutMs == 50)
        #expect(warnings.lines.isEmpty)
    }

    // MARK: - the engine rename

    /// `local` was renamed `apple` when the bundled MLX engine arrived. This is
    /// not a courtesy: `Config.load` discards the *whole file* on any decoding
    /// failure, so without the alias an existing
    /// `{"engine": "local", "cloud": {...}}` would silently lose its cloud
    /// section and its timeout as well as its engine.
    @Test("a config written before the rename still decodes, and keeps its siblings")
    func legacyLocalEngineStillDecodes() {
        let warnings = Warnings()
        let cfg = Config.load(
            from: write(#"{"engine":"local","timeoutMs":900,"cloud":{}}"#),
            warn: warnings.sink)
        #expect(cfg.engine == .apple)
        #expect(cfg.timeoutMs == 900)
        #expect(cfg.cloud?.provider == "anthropic")
        #expect(warnings.lines.isEmpty)
    }

    @Test("the new engine names decode")
    func newEngineNamesDecode() {
        #expect(Config.load(from: write(#"{"engine":"mlx"}"#)).engine == .mlx)
        #expect(Config.load(from: write(#"{"engine":"apple"}"#)).engine == .apple)
    }

    @Test("reads every field")
    func fullFile() {
        let cfg = Config.load(from: write(#"""
        {"engine":"cloud","timeoutMs":900,"mode":"email","hotkey":"right-command"}
        """#))
        #expect(cfg.engine == .cloud)
        #expect(cfg.timeoutMs == 900)
        #expect(cfg.mode == "email")
        #expect(cfg.hotkey == "right-command")
    }

    // MARK: - microphone

    @Test("microphone decodes when present")
    func microphonePresent() {
        let warnings = Warnings()
        let cfg = Config.load(
            from: write(#"{"microphone":"AppleUSBAudioEngine:Blue:Yeti:123:1"}"#),
            warn: warnings.sink)
        #expect(cfg.microphone == "AppleUSBAudioEngine:Blue:Yeti:123:1")
        #expect(warnings.lines.isEmpty)
    }

    @Test("microphone defaults to unset when absent")
    func microphoneAbsent() {
        #expect(Config.load(from: write("{}")).microphone == nil)
    }

    @Test("a null microphone is unset and silent")
    func microphoneNull() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"microphone":null}"#), warn: warnings.sink)
        #expect(cfg.microphone == nil)
        #expect(warnings.lines.isEmpty)
    }

    /// The stronger guarantee the other keys do not have: a garbage
    /// `microphone` must never discard the rest of the file. Unplugging a USB
    /// mic and hand-editing the config is exactly the situation where the user
    /// is most likely to typo this key, and losing their cloud section over it
    /// would turn a routing preference into an engine downgrade.
    @Test("a wrongly typed microphone warns and keeps every sibling")
    func microphoneWrongTypeKeepsSiblings() {
        let warnings = Warnings()
        let url = write(#"{"engine":"rules","timeoutMs":900,"microphone":42}"#)
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.engine == .rules)      // not the default — the file survived
        #expect(cfg.timeoutMs == 900)
        #expect(cfg.microphone == nil)
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains(url.path))
        #expect(warnings.joined.contains("microphone"))
    }

    @Test("an array-typed microphone behaves as unset, siblings intact")
    func microphoneArrayKeepsSiblings() {
        let warnings = Warnings()
        let cfg = Config.load(
            from: write(#"{"microphone":["a","b"],"cloud":{"model":"m"}}"#),
            warn: warnings.sink)
        #expect(cfg.microphone == nil)
        #expect(cfg.cloud?.model == "m")
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains("microphone"))
    }

    // MARK: - persistMicrophone rewrites one key and spares the rest

    private func json(at url: URL) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return parsed as? [String: Any] ?? [:]
    }

    /// The critical property: a menu pick must not destroy keys this version
    /// of ara does not know about. A user running a newer config against an
    /// older binary would otherwise lose settings by touching a menu.
    @Test("setting the key preserves every other key, known and unknown")
    func persistPreservesUnknownKeys() throws {
        let url = write(#"""
        {"engine":"rules","timeoutMs":900,"cloud":{"model":"m"},
         "futureKey":{"nested":[1,2]},"flag":true}
        """#)
        try Config.persistMicrophone("uid-x", at: url)

        let saved = try json(at: url)
        #expect(saved["microphone"] as? String == "uid-x")
        #expect(saved["engine"] as? String == "rules")
        #expect(saved["timeoutMs"] as? Int == 900)
        #expect((saved["cloud"] as? [String: Any])?["model"] as? String == "m")
        #expect((saved["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        #expect(saved["flag"] as? Bool == true)

        // And the rewritten file still loads without a single warning.
        let warnings = Warnings()
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.microphone == "uid-x")
        #expect(cfg.engine == .rules)
        #expect(warnings.lines.isEmpty)
    }

    @Test("clearing the key removes only it")
    func persistRemoveOnlyMicrophone() throws {
        let url = write(#"{"microphone":"old","futureKey":"survives"}"#)
        try Config.persistMicrophone(nil, at: url)
        let saved = try json(at: url)
        #expect(!saved.keys.contains("microphone"))
        #expect(saved["futureKey"] as? String == "survives")
    }

    @Test("setting the key overwrites a previous pick")
    func persistOverwritesPreviousPick() throws {
        let url = write(#"{"microphone":"old"}"#)
        try Config.persistMicrophone("new", at: url)
        #expect(try json(at: url)["microphone"] as? String == "new")
    }

    @Test("a missing file is created, directories included, when setting")
    func persistCreatesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-cfg-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
        try Config.persistMicrophone("uid-x", at: url)
        let saved = try json(at: url)
        #expect(saved["microphone"] as? String == "uid-x")
        #expect(saved.count == 1)
    }

    @Test("a missing file stays missing when clearing — nothing to remove")
    func persistMissingFileStaysMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-cfg-\(UUID().uuidString).json")
        try Config.persistMicrophone(nil, at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A file that cannot be parsed cannot be selectively rewritten; writing
    /// anyway would replace the user's (repairable) file with our guess at it.
    @Test("a malformed file throws and is left byte-for-byte untouched")
    func persistMalformedUntouched() throws {
        let url = write("{ not json")
        #expect(throws: (any Error).self) {
            try Config.persistMicrophone("uid-x", at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test("a non-object top level throws and is left untouched")
    func persistNonObjectUntouched() throws {
        let url = write("[1,2,3]")
        #expect(throws: (any Error).self) {
            try Config.persistMicrophone("uid-x", at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[1,2,3]")
    }

    // MARK: - persistCleanup: the same one-key rewrite, for the Cleanup menu

    /// The same critical property `persistMicrophone` pins: a menu pick must
    /// not destroy keys this version of ara does not know about.
    @Test("persisting cleanup preserves every other key, known and unknown")
    func persistCleanupPreservesUnknownKeys() throws {
        let url = write(#"""
        {"engine":"rules","timeoutMs":900,"cloud":{"model":"m"},
         "futureKey":{"nested":[1,2]},"flag":true}
        """#)
        try Config.persistCleanup(.high, at: url)

        let saved = try json(at: url)
        #expect(saved["cleanup"] as? String == "high")
        #expect(saved["engine"] as? String == "rules")
        #expect(saved["timeoutMs"] as? Int == 900)
        #expect((saved["cloud"] as? [String: Any])?["model"] as? String == "m")
        #expect((saved["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        #expect(saved["flag"] as? Bool == true)

        // And the rewritten file still loads without a single warning.
        let warnings = Warnings()
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.cleanup == .high)
        #expect(cfg.engine == .rules)
        #expect(warnings.lines.isEmpty)
    }

    @Test("persisting cleanup overwrites a previous pick")
    func persistCleanupOverwritesPreviousPick() throws {
        let url = write(#"{"cleanup":"none"}"#)
        try Config.persistCleanup(.light, at: url)
        #expect(try json(at: url)["cleanup"] as? String == "light")
    }

    @Test("a missing config file is created, directories included")
    func persistCleanupCreatesFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-cfg-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
        try Config.persistCleanup(.none, at: url)
        let saved = try json(at: url)
        #expect(saved["cleanup"] as? String == "none")
        #expect(saved.count == 1)
    }

    /// A file that cannot be parsed cannot be selectively rewritten; writing
    /// anyway would replace the user's (repairable) file with our guess at it.
    @Test("persisting cleanup into a malformed file throws, bytes untouched")
    func persistCleanupMalformedUntouched() throws {
        let url = write("{ not json")
        #expect(throws: (any Error).self) {
            try Config.persistCleanup(.high, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test("persisting cleanup into a non-object top level throws, untouched")
    func persistCleanupNonObjectUntouched() throws {
        let url = write("[1,2,3]")
        #expect(throws: (any Error).self) {
            try Config.persistCleanup(.high, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[1,2,3]")
    }

    // MARK: - persistModel / persistHotkey / persistEngine: the menu's other
    // one-key rewrites, each pinned to the same two critical properties

    @Test("persisting a model preserves every other key, known and unknown")
    func persistModelPreservesUnknownKeys() throws {
        let url = write(#"""
        {"engine":"rules","timeoutMs":900,"cloud":{"model":"m"},
         "futureKey":{"nested":[1,2]},"flag":true}
        """#)
        try Config.persistModel("whisper-small.en", at: url)

        let saved = try json(at: url)
        #expect(saved["model"] as? String == "whisper-small.en")
        #expect(saved["engine"] as? String == "rules")
        #expect(saved["timeoutMs"] as? Int == 900)
        #expect((saved["cloud"] as? [String: Any])?["model"] as? String == "m")
        #expect((saved["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        #expect(saved["flag"] as? Bool == true)

        // And the rewritten file still loads without a single warning.
        let warnings = Warnings()
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.model == "whisper-small.en")
        #expect(warnings.lines.isEmpty)
    }

    @Test("persisting a model into a malformed file throws, bytes untouched")
    func persistModelMalformedUntouched() throws {
        let url = write("{ not json")
        #expect(throws: (any Error).self) {
            try Config.persistModel("whisper-small.en", at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test("persisting a hotkey preserves every other key, known and unknown")
    func persistHotkeyPreservesUnknownKeys() throws {
        let url = write(#"{"engine":"rules","futureKey":{"nested":[1,2]}}"#)
        try Config.persistHotkey(.rightCommand, at: url)

        let saved = try json(at: url)
        #expect(saved["hotkey"] as? String == "right-command")
        #expect(saved["engine"] as? String == "rules")
        #expect((saved["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])

        let warnings = Warnings()
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.hotkey == "right-command")
        #expect(warnings.lines.isEmpty)
    }

    @Test("persisting a hotkey into a malformed file throws, bytes untouched")
    func persistHotkeyMalformedUntouched() throws {
        let url = write("{ not json")
        #expect(throws: (any Error).self) {
            try Config.persistHotkey(.fn, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test("persisting an engine preserves every other key, known and unknown")
    func persistEnginePreservesUnknownKeys() throws {
        let url = write(#"{"timeoutMs":900,"futureKey":{"nested":[1,2]}}"#)
        try Config.persistEngine(.cloud, at: url)

        let saved = try json(at: url)
        #expect(saved["engine"] as? String == "cloud")
        #expect(saved["timeoutMs"] as? Int == 900)
        #expect((saved["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])

        let warnings = Warnings()
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.engine == .cloud)
        #expect(warnings.lines.isEmpty)
    }

    @Test("persisting an engine into a malformed file throws, bytes untouched")
    func persistEngineMalformedUntouched() throws {
        let url = write("{ not json")
        #expect(throws: (any Error).self) {
            try Config.persistEngine(.rules, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    // MARK: - persistLanguage: the one rewrite that writes something other
    // than a string, with all of the same guarantees

    @Test("persisting a language preserves every other key, known and unknown")
    func persistLanguagePreservesUnknownKeys() throws {
        let url = write(#"""
        {"engine":"rules","timeoutMs":900,"cloud":{"model":"m"},
         "futureKey":{"nested":[1,2]},"flag":true}
        """#)
        try Config.persistLanguage(.monitored(["en", "pl"]), at: url)

        let saved = try json(at: url)
        #expect(saved["language"] as? [String] == ["en", "pl"])
        #expect(saved["engine"] as? String == "rules")
        #expect(saved["timeoutMs"] as? Int == 900)
        #expect((saved["cloud"] as? [String: Any])?["model"] as? String == "m")
        #expect((saved["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        #expect(saved["flag"] as? Bool == true)

        let warnings = Warnings()
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.language == .monitored(["en", "pl"]))
        #expect(cfg.engine == .rules)
        #expect(warnings.lines.isEmpty)
    }

    /// One language stays a plain string so a hand-written `"language": "pl"`
    /// survives a menu click looking the way its author wrote it.
    @Test("one language is written as a string, several as an array, auto as auto")
    func persistLanguageShapes() throws {
        let single = write("{}")
        try Config.persistLanguage(.monitored(["pl"]), at: single)
        #expect(try json(at: single)["language"] as? String == "pl")

        let set = write("{}")
        try Config.persistLanguage(.monitored(["en", "pl"]), at: set)
        #expect(try json(at: set)["language"] as? [String] == ["en", "pl"])

        let auto = write(#"{"language":["en","pl"]}"#)
        try Config.persistLanguage(.automatic, at: auto)
        #expect(try json(at: auto)["language"] as? String == "auto")
        #expect(Config.load(from: auto).language == .automatic)
    }

    @Test("persisting a language into a malformed file throws, bytes untouched")
    func persistLanguageMalformedUntouched() throws {
        let url = write("{ not json")
        #expect(throws: (any Error).self) {
            try Config.persistLanguage(.monitored(["pl"]), at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test("persisting a language into a non-object top level throws, untouched")
    func persistLanguageNonObjectUntouched() throws {
        let url = write("[1,2,3]")
        #expect(throws: (any Error).self) {
            try Config.persistLanguage(.automatic, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "[1,2,3]")
    }

    // MARK: - language

    @Test("language decodes both spellings a person would write")
    func languageDecodes() {
        #expect(Config.load(from: write(#"{"language":"auto"}"#)).language == .automatic)
        #expect(Config.load(from: write(#"{"language":"pl"}"#)).language == .monitored(["pl"]))
        #expect(Config.load(from: write(#"{"language":"en,pl"}"#)).language
                == .monitored(["en", "pl"]))
        #expect(Config.load(from: write(#"{"language":["en","pl"]}"#)).language
                == .monitored(["en", "pl"]))
    }

    /// The default that fixes the reported bug. `automatic` costs an
    /// English-only model nothing — `LanguagePlan` collapses it to today's
    /// `DecodingOptions` — and gives a multilingual model the detection its
    /// owner chose 1.6 GB of weights for.
    @Test("language defaults to automatic when absent, silently")
    func languageAbsentIsAutomatic() {
        let warnings = Warnings()
        let cfg = Config.load(from: write("{}"), warn: warnings.sink)
        #expect(cfg.language == .automatic)
        #expect(Config().language == .automatic)
        #expect(warnings.lines.isEmpty)
    }

    @Test("a null language is automatic and silent")
    func languageNull() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"language":null}"#), warn: warnings.sink)
        #expect(cfg.language == .automatic)
        #expect(warnings.lines.isEmpty)
    }

    /// The `cleanup` guarantee, extended to `language`: a mistyped language
    /// code must never discard the file. Losing a `cloud` section over
    /// `"pll"` would turn a spelling mistake into an engine downgrade.
    @Test("an unknown language code warns, keeps every sibling, and detects")
    func languageInvalidKeepsSiblings() {
        let warnings = Warnings()
        let url = write(#"{"engine":"rules","timeoutMs":900,"language":"pll"}"#)
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.engine == .rules)      // not the default — the file survived
        #expect(cfg.timeoutMs == 900)
        #expect(cfg.language == .automatic)
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains(url.path))
        #expect(warnings.joined.contains("language"))
        // The warning names the offending code and teaches the valid shapes.
        #expect(warnings.joined.contains("pll"))
        #expect(warnings.joined.contains("auto"))
    }

    @Test("one bad code in a list is enough to warn, and the file survives")
    func languageBadCodeInList() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"language":["en","pll"],"cloud":{"model":"m"}}"#),
                              warn: warnings.sink)
        #expect(cfg.language == .automatic)
        #expect(cfg.cloud?.model == "m")
        #expect(warnings.joined.contains("pll"))
    }

    @Test("an empty language list warns rather than silently meaning auto")
    func languageEmptyList() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"language":[]}"#), warn: warnings.sink)
        #expect(cfg.language == .automatic)
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains("language"))
    }

    @Test("a wrongly typed language behaves as unset, siblings intact")
    func languageWrongTypeKeepsSiblings() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"language":42,"cloud":{"model":"m"}}"#),
                              warn: warnings.sink)
        #expect(cfg.language == .automatic)
        #expect(cfg.cloud?.model == "m")
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains("language"))
    }

    @Test("a partial cloud object keeps sibling settings and cloud defaults")
    func partialCloudObject() {
        let cfg = Config.load(from: write(#"""
        {"engine":"cloud","timeoutMs":900,"cloud":{"model":"claude-opus-5"}}
        """#))
        #expect(cfg.engine == .cloud)
        #expect(cfg.timeoutMs == 900)
        #expect(cfg.cloud?.model == "claude-opus-5")
        #expect(cfg.cloud?.provider == "anthropic")
        #expect(cfg.cloud?.keychainAccount == "ara-cloud")
    }

    @Test("an empty cloud object yields all cloud defaults")
    func emptyCloudObject() {
        let cfg = Config.load(from: write(#"{"cloud":{}}"#))
        #expect(cfg.cloud?.provider == "anthropic")
        #expect(cfg.cloud?.model == "claude-opus-5")
        #expect(cfg.cloud?.keychainAccount == "ara-cloud")
    }

    // MARK: - inject / pasteRestoreMs

    @Test("inject decodes as a raw string and defaults to absent")
    func injectDecodes() {
        #expect(Config.load(from: write(#"{"inject":"paste"}"#)).inject == "paste")
        #expect(Config.load(from: write(#"{}"#)).inject == nil)
    }

    @Test("pasteRestoreMs decodes and defaults to 300")
    func pasteRestoreMsDecodes() {
        #expect(Config.load(from: write(#"{"pasteRestoreMs":150}"#)).pasteRestoreMs == 150)
        #expect(Config.load(from: write(#"{}"#)).pasteRestoreMs == 300)
    }

    @Test("a too-small pasteRestoreMs is clamped up and warned about")
    func pasteRestoreMsClampedLow() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"pasteRestoreMs":0}"#), warn: warnings.sink)
        #expect(cfg.pasteRestoreMs == Config.minimumPasteRestoreMs)
        #expect(warnings.joined.contains("pasteRestoreMs"))
    }

    @Test("an absurdly large pasteRestoreMs is clamped down and warned about")
    func pasteRestoreMsClampedHigh() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"pasteRestoreMs":60000}"#), warn: warnings.sink)
        #expect(cfg.pasteRestoreMs == Config.maximumPasteRestoreMs)
        #expect(warnings.joined.contains("pasteRestoreMs"))
    }

    @Test("a deliberately slow but sane pasteRestoreMs survives")
    func pasteRestoreMsInRangeKept() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"pasteRestoreMs":1000}"#), warn: warnings.sink)
        #expect(cfg.pasteRestoreMs == 1000)
        #expect(warnings.lines.isEmpty)
    }
    // MARK: - cleanup

    @Test("cleanup decodes every intensity")
    func cleanupDecodes() {
        #expect(Config.load(from: write(#"{"cleanup":"none"}"#)).cleanup == CleanupIntensity.none)
        #expect(Config.load(from: write(#"{"cleanup":"light"}"#)).cleanup == .light)
        #expect(Config.load(from: write(#"{"cleanup":"medium"}"#)).cleanup == .medium)
        #expect(Config.load(from: write(#"{"cleanup":"high"}"#)).cleanup == .high)
    }

    @Test("cleanup defaults to medium when absent — today's behaviour")
    func cleanupAbsentIsMedium() {
        let warnings = Warnings()
        let cfg = Config.load(from: write("{}"), warn: warnings.sink)
        #expect(cfg.cleanup == .medium)
        #expect(warnings.lines.isEmpty)
    }

    @Test("a null cleanup is medium and silent")
    func cleanupNull() {
        let warnings = Warnings()
        let cfg = Config.load(from: write(#"{"cleanup":null}"#), warn: warnings.sink)
        #expect(cfg.cleanup == .medium)
        #expect(warnings.lines.isEmpty)
    }

    /// The microphone guarantee, extended to `cleanup`: a typo in an editing
    /// preference must never discard the file — losing the cloud section over
    /// `"cleanup": "hgih"` would turn a taste setting into an engine downgrade.
    @Test("an invalid cleanup warns, keeps every sibling, and uses medium")
    func cleanupInvalidKeepsSiblings() {
        let warnings = Warnings()
        let url = write(#"{"engine":"rules","timeoutMs":900,"cleanup":"hgih"}"#)
        let cfg = Config.load(from: url, warn: warnings.sink)
        #expect(cfg.engine == .rules)      // not the default — the file survived
        #expect(cfg.timeoutMs == 900)
        #expect(cfg.cleanup == .medium)
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains(url.path))
        #expect(warnings.joined.contains("cleanup"))
        // The warning teaches the valid spellings rather than only rejecting.
        #expect(warnings.joined.contains("none, light, medium, high"))
    }

    @Test("a wrongly typed cleanup behaves as unset, siblings intact")
    func cleanupWrongTypeKeepsSiblings() {
        let warnings = Warnings()
        let cfg = Config.load(
            from: write(#"{"cleanup":42,"cloud":{"model":"m"}}"#),
            warn: warnings.sink)
        #expect(cfg.cleanup == .medium)
        #expect(cfg.cloud?.model == "m")
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains("cleanup"))
    }
}

@Suite("KeychainService")
struct KeychainServiceTests {
    /// The rebrand left the keychain service as `com.digimata.ara` — half the
    /// old vendor, half the new product, matching nothing. It is now
    /// `com.silpho.ara`, the same reverse-DNS prefix as the launch agent
    /// label, with the old string kept read-only so a key stored under it
    /// still resolves.
    @Test("the service matches the launch agent's prefix and the legacy one is kept")
    func servicesAreNamedForTheProduct() {
        #expect(Keychain.service == "com.silpho.ara")
        #expect(Keychain.legacyService == "com.digimata.ara")
        #expect(Keychain.service != Keychain.legacyService)
    }
}
