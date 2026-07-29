import Testing
@testable import AraCore

@Suite("OutputGuard")
struct OutputGuardTests {
    @Test("rejects an answer masquerading as a rewrite")
    func rejectsAnswer() {
        #expect(!OutputGuard.isPlausible(
            input: "what is the capital of France",
            output: "Paris"))
    }

    @Test("rejects empty and whitespace output")
    func rejectsEmpty() {
        #expect(!OutputGuard.isPlausible(input: "hello there", output: ""))
        #expect(!OutputGuard.isPlausible(input: "hello there", output: "   "))
    }

    @Test("rejects runaway expansion")
    func rejectsExpansion() {
        let input = "send the report"
        let output = String(repeating: "word ", count: 40)
        #expect(!OutputGuard.isPlausible(input: input, output: output))
    }

    @Test("accepts an ordinary cleanup")
    func acceptsCleanup() {
        #expect(OutputGuard.isPlausible(
            input: "um so I think uh we should ship it on friday",
            output: "So I think we should ship it on Friday."))
    }

    @Test("short inputs only bound expansion")
    func shortInputs() {
        #expect(OutputGuard.isPlausible(input: "ok", output: "OK."))
        #expect(!OutputGuard.isPlausible(input: "ok", output: "Okay, sure, absolutely, yes."))
    }
}
