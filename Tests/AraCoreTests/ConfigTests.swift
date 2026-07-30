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
    /// of parrot does not know about. A user running a newer config against an
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
}
