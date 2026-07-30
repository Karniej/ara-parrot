import Foundation
import Testing
@testable import AraCore

@Suite("Modes")
struct ModeTests {
    let registry = ModeRegistry(userModes: [])

    @Test("ships the five built-in modes")
    func builtIns() {
        for id in ["verbatim", "default", "email", "chat", "code"] {
            #expect(registry.mode(id: id) != nil, "missing built-in \(id)")
        }
    }

    @Test("verbatim skips the LLM")
    func verbatimSkipsLLM() {
        #expect(registry.mode(id: "verbatim")?.usesLLM == false)
        #expect(registry.mode(id: "default")?.usesLLM == true)
    }

    @Test("user modes override built-ins with the same id")
    func userOverride() {
        let custom = Mode(id: "email", name: "My Email", prompt: "custom",
                          appBundleIDs: [], usesLLM: true)
        let r = ModeRegistry(userModes: [custom])
        #expect(r.mode(id: "email")?.name == "My Email")
    }

    @Test("explicit override wins over everything")
    func overrideWins() {
        let resolver = ModeResolver(registry: registry, defaultID: "default")
        let m = resolver.resolve(override: "code", manual: "email",
                                 frontmostBundleID: "com.apple.mail")
        #expect(m.id == "code")
    }

    @Test("manual selection beats frontmost app")
    func manualBeatsApp() {
        let resolver = ModeResolver(registry: registry, defaultID: "default")
        let m = resolver.resolve(override: nil, manual: "chat",
                                 frontmostBundleID: "com.apple.mail")
        #expect(m.id == "chat")
    }

    @Test("frontmost app selects a matching mode")
    func appMatch() {
        let resolver = ModeResolver(registry: registry, defaultID: "default")
        let m = resolver.resolve(override: nil, manual: nil,
                                 frontmostBundleID: "com.apple.mail")
        #expect(m.id == "email")
    }

    @Test("unknown app falls back to the default mode")
    func unknownApp() {
        let resolver = ModeResolver(registry: registry, defaultID: "default")
        let m = resolver.resolve(override: nil, manual: nil,
                                 frontmostBundleID: "com.example.unknown")
        #expect(m.id == "default")
    }

    @Test("unknown override id falls back rather than crashing")
    func unknownOverride() {
        let resolver = ModeResolver(registry: registry, defaultID: "default")
        let m = resolver.resolve(override: "nope", manual: nil, frontmostBundleID: nil)
        #expect(m.id == "default")
    }

    // MARK: - cleanup intensity riding the mode

    @Test("a mode is built at medium cleanup unless told otherwise")
    func modeDefaultsToMedium() {
        #expect(ModeRegistry.defaultMode.cleanup == .medium)
    }

    @Test("applying an intensity carries it and preserves the mode's identity")
    func applyingCarriesIntensity() {
        let applied = ModeRegistry.defaultMode.applying(cleanup: .high)
        #expect(applied.cleanup == .high)
        #expect(applied.id == "default")
        #expect(applied.name == "Default")
        #expect(applied.prompt == ModeRegistry.defaultMode.prompt)
        #expect(applied.usesLLM)
    }

    /// The verbatim seam: `cleanup: none` must reach `FormatterChain` as the
    /// same property verbatim mode uses, so no chain logic changes at all.
    @Test("applying none turns the LLM off")
    func applyingNoneDisablesLLM() {
        #expect(ModeRegistry.defaultMode.applying(cleanup: CleanupIntensity.none)
            .usesLLM == false)
    }

    @Test("no intensity can turn the LLM on for a verbatim mode")
    func applyingNeverEnablesLLM() {
        let verbatim = registry.mode(id: "verbatim")!
        for intensity in CleanupIntensity.allCases {
            #expect(verbatim.applying(cleanup: intensity).usesLLM == false)
        }
    }

    /// User modes are documented as decodable from `config.json`; a mode file
    /// written before `cleanup` existed must keep decoding, at the default.
    @Test("a mode encoded before cleanup existed still decodes, at medium")
    func modeWithoutCleanupKeyDecodes() throws {
        let json = #"""
        {"id":"x","name":"X","prompt":"p","appBundleIDs":[],"usesLLM":true}
        """#
        let mode = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(mode.cleanup == .medium)
        #expect(mode.usesLLM)
    }

    @Test("a mode round-trips its cleanup through Codable")
    func modeCleanupRoundTrips() throws {
        let mode = Mode(id: "x", name: "X", prompt: "p", appBundleIDs: [],
                        usesLLM: true, cleanup: .light)
        let data = try JSONEncoder().encode(mode)
        #expect(try JSONDecoder().decode(Mode.self, from: data).cleanup == .light)
    }

    @Test("a duplicated user mode id yields last-write-wins with no duplicate entry")
    func duplicateUserModeIDs() {
        let first = Mode(id: "email", name: "First", prompt: "a",
                         appBundleIDs: [], usesLLM: true)
        let second = Mode(id: "email", name: "Second", prompt: "b",
                          appBundleIDs: [], usesLLM: true)
        let r = ModeRegistry(userModes: [first, second])
        #expect(r.mode(id: "email")?.name == "Second")
        #expect(r.all.filter { $0.id == "email" }.count == 1)
    }

    /// The bug this pins: `code` mode listed `com.cmuxterm.app`, an identifier
    /// no shipping application has ever had, so dictating into a terminal
    /// resolved to `default` and got prose treatment — identifiers reworded,
    /// paths punctuated. Every id here is one `InjectionPolicy` also knows.
    @Test("terminals and editors resolve to code mode")
    func terminalsResolveToCode() {
        let resolver = ModeResolver(registry: ModeRegistry(userModes: []),
                                    defaultID: "default")
        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2",
                       "net.kovidgoyal.kitty", "org.alacritty",
                       "com.github.wez.wezterm", "com.microsoft.VSCode",
                       "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92"] {
            let m = resolver.resolve(override: nil, manual: nil,
                                     frontmostBundleID: bundle)
            #expect(m.id == "code", "\(bundle) resolved to \(m.id)")
        }
    }
}
