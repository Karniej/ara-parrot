import Foundation
import Testing
@testable import AraCore

/// Covers the precedence the spec documents — CLI flags > config > defaults —
/// for the two keys that decoded, were asserted by a `Config` test, and were
/// then never read by anything.
@Suite("StartupResolution")
struct StartupResolutionTests {
    private final class Warnings: @unchecked Sendable {
        private(set) var lines: [String] = []
        var sink: (String) -> Void { { self.lines.append($0) } }
        var joined: String { lines.joined(separator: "\n") }
    }

    // MARK: - hotkey

    @Test("the flag outranks the config")
    func hotkeyFlagWins() {
        let warnings = Warnings()
        let resolved = StartupResolution.hotkey(flag: .rightShift, config: "right-command",
                                                warn: warnings.sink)
        #expect(resolved == .rightShift)
        #expect(warnings.lines.isEmpty)
    }

    /// The regression test for the finding. Before this existed, a user who
    /// followed the spec and wrote `"hotkey": "right-command"` got Fn.
    @Test("config.hotkey is honoured when no flag is given")
    func hotkeyFromConfig() {
        let warnings = Warnings()
        #expect(StartupResolution.hotkey(flag: nil, config: "right-command",
                                         warn: warnings.sink) == .rightCommand)
        #expect(warnings.lines.isEmpty)
    }

    @Test("every hotkey name in the enum round-trips through the config")
    func everyHotkeyFromConfig() {
        for hotkey in Hotkey.allCases {
            #expect(StartupResolution.hotkey(flag: nil, config: hotkey.rawValue,
                                             warn: { _ in }) == hotkey)
        }
    }

    @Test("no flag and no config yields fn")
    func hotkeyDefault() {
        #expect(StartupResolution.hotkey(flag: nil, config: nil, warn: { _ in }) == .fn)
    }

    @Test("an unparseable config hotkey warns and falls back rather than exiting")
    func hotkeyUnparseable() {
        let warnings = Warnings()
        let resolved = StartupResolution.hotkey(flag: nil, config: "right-meta",
                                                warn: warnings.sink)
        #expect(resolved == .fn)
        #expect(warnings.joined.contains("right-meta"))
        #expect(warnings.joined.contains("right-command"))  // lists what is valid
    }

    // MARK: - model

    @Test("the model flag outranks the config")
    func modelFlagWins() {
        let warnings = Warnings()
        let choice = StartupResolution.model(flag: "whisper-small",
                                             config: "whisper-large-v3-turbo",
                                             warn: warnings.sink)
        guard case .chosen(let model) = choice else { Issue.record("not chosen"); return }
        #expect(model.id == "whisper-small")
        #expect(warnings.lines.isEmpty)
    }

    @Test("config.model is honoured when no flag is given")
    func modelFromConfig() {
        let warnings = Warnings()
        let choice = StartupResolution.model(flag: nil, config: "whisper-large-v3-turbo",
                                             warn: warnings.sink)
        guard case .chosen(let model) = choice else { Issue.record("not chosen"); return }
        #expect(model.id == "whisper-large-v3-turbo")
        #expect(warnings.lines.isEmpty)
    }

    @Test("no flag and no config yields the recommended model")
    func modelDefault() {
        let choice = StartupResolution.model(flag: nil, config: nil, warn: { _ in })
        guard case .chosen(let model) = choice else { Issue.record("not chosen"); return }
        #expect(model.recommended)
    }

    @Test("an unknown model flag is fatal — the user just typed it")
    func modelUnknownFlag() {
        let choice = StartupResolution.model(flag: "whisper-enormous", config: nil,
                                             warn: { _ in })
        guard case .unknownFlag(let id) = choice else { Issue.record("not unknownFlag"); return }
        #expect(id == "whisper-enormous")
    }

    @Test("an unknown model in config warns and falls back to the recommended one")
    func modelUnknownInConfig() {
        let warnings = Warnings()
        let choice = StartupResolution.model(flag: nil, config: "whisper-enormous",
                                             warn: warnings.sink)
        guard case .chosen(let model) = choice else { Issue.record("not chosen"); return }
        #expect(model.recommended)
        #expect(warnings.joined.contains("whisper-enormous"))
    }

    // MARK: - injection

    @Test("the --inject flag outranks config.inject")
    func injectionFlagWins() {
        let warnings = Warnings()
        #expect(StartupResolution.injection(flag: .type, config: "paste",
                                            warn: warnings.sink) == .type)
        #expect(warnings.lines.isEmpty)
    }

    @Test("every injection setting round-trips through the config")
    func everyInjectionFromConfig() {
        for setting in InjectionSetting.allCases {
            #expect(StartupResolution.injection(flag: nil, config: setting.rawValue,
                                                warn: { _ in }) == setting)
        }
    }

    @Test("no flag and no config yields auto")
    func injectionDefault() {
        #expect(StartupResolution.injection(flag: nil, config: nil,
                                            warn: { _ in }) == .auto)
    }

    @Test("an unparseable config inject warns and falls back rather than exiting")
    func injectionUnparseable() {
        let warnings = Warnings()
        let resolved = StartupResolution.injection(flag: nil, config: "clipboard",
                                                   warn: warnings.sink)
        #expect(resolved == .auto)
        #expect(warnings.joined.contains("clipboard"))
        #expect(warnings.joined.contains("paste"))  // lists what is valid
    }
}
