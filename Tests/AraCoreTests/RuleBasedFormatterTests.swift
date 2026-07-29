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

    @Test("preserves 'like' as a verb")
    func preservesLike() async throws {
        #expect(try await f.format("I would like to go", mode: mode) == "I would like to go")
    }

    @Test("preserves literal 'you know' and 'I mean'")
    func preservesDiscoursePhrasesUsedLiterally() async throws {
        #expect(try await f.format("Do you know what time it is?", mode: mode)
                == "Do you know what time it is?")
        #expect(try await f.format("I mean it", mode: mode) == "I mean it")
    }

    @Test("does not break hyphenated interjections")
    func preservesHyphenated() async throws {
        #expect(try await f.format("uh-huh, that works", mode: mode) == "uh-huh, that works")
        #expect(try await f.format("uh-oh, we broke it", mode: mode) == "uh-oh, we broke it")
    }

    @Test("preserves unit abbreviations")
    func preservesUnits() async throws {
        #expect(try await f.format("battery rated at 60 Ah", mode: mode)
                == "battery rated at 60 Ah")
    }

    @Test("punctuation-only residue returns the original")
    func punctuationResidue() async throws {
        #expect(try await f.format("Um, uh...", mode: mode) == "Um, uh...")
    }
}
