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
        #expect(cfg.engine == .local)
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
        #expect(cfg.engine == .local)
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
        #expect(cfg.engine == .local)
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
}
