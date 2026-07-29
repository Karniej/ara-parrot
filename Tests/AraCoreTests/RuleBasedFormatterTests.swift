import Testing
@testable import AraCore

@Suite("RuleBasedFormatter")
struct RuleBasedFormatterTests {
    let f = RuleBasedFormatter()
    let mode = Mode(id: "default", name: "Default", prompt: "", appBundleIDs: [], usesLLM: false)

    @Test("removes standalone filler words")
    func removesFiller() async throws {
        #expect(try await f.format("um so I think uh we should go", mode: mode)
                == "so I think we should go")
    }

    @Test("does not butcher words containing filler as a substring")
    func preservesSubstrings() async throws {
        #expect(try await f.format("the drum is humming", mode: mode) == "the drum is humming")
    }

    @Test("collapses whitespace left behind")
    func collapsesWhitespace() async throws {
        #expect(try await f.format("hello   um   world", mode: mode) == "hello world")
    }

    @Test("never returns empty for non-empty input")
    func neverEmpties() async throws {
        #expect(try await f.format("um", mode: mode) == "um")
    }

    @Test("leaves clean text untouched")
    func leavesCleanText() async throws {
        #expect(try await f.format("Ship it on Friday.", mode: mode) == "Ship it on Friday.")
    }

    // Documents the actual behavior of "like" in the filler list (ruling #3
    // in the task-3 brief): it strips *all* standalone occurrences of "like",
    // including ones that carry meaning as a verb, not just filler usage
    // ("like, totally"). This is a known false-positive, kept as written per
    // the brief pending a decision from the plan owner.
    @Test("strips \"like\" even when it changes the meaning of the sentence")
    func likeIsOverEager() async throws {
        #expect(try await f.format("I would like to go", mode: mode) == "I would to go")
    }
}
