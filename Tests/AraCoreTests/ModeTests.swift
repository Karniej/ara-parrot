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
}
