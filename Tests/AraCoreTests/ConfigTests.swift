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
}
