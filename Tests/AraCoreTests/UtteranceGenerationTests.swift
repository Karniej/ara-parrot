import Foundation
import Testing
@testable import AraCore

/// The counter that decides whether a finished utterance is still allowed to
/// clear the screen. The bug it exists for is two utterances overlapping: the
/// user speaks, releases, and starts speaking again while the first one is
/// still transcribing — so the first one's completion arrives *after* a newer
/// recording is already on screen.
@Suite("Utterance generation")
@MainActor
struct UtteranceGenerationTests {
    @Test("the only utterance is current")
    func single() {
        let utterances = UtteranceGeneration()
        let token = utterances.begin()
        #expect(utterances.isCurrent(token))
    }

    @Test("a newer utterance retires the older token")
    func superseded() {
        let utterances = UtteranceGeneration()
        let first = utterances.begin()
        let second = utterances.begin()
        #expect(!utterances.isCurrent(first))
        #expect(utterances.isCurrent(second))
    }

    @Test("tokens are never reused, so a stale one can never come back")
    func distinct() {
        let utterances = UtteranceGeneration()
        let tokens = (0 ..< 5).map { _ in utterances.begin() }
        #expect(Set(tokens).count == tokens.count)
        #expect(utterances.isCurrent(tokens.last!))
        #expect(tokens.dropLast().allSatisfy { !utterances.isCurrent($0) })
    }

    @Test("no utterance has begun, so no token is current")
    func beforeAnyUtterance() {
        let utterances = UtteranceGeneration()
        #expect(!utterances.isCurrent(0))
        #expect(!utterances.isCurrent(1))
    }
}
