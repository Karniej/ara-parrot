import XCTest
@testable import Ara

@MainActor
final class UtteranceStateTests: XCTestCase {
    func testFinalTailDoesNotReplaceCompleteUtterance() {
        let utterance = UtteranceState()

        XCTAssertEqual(
            utterance.observe("Ara should insert this whole message"),
            "Ara should insert this whole message"
        )
        XCTAssertEqual(
            utterance.observe("this whole message"),
            "Ara should insert this whole message"
        )
    }

    func testShiftedRecognitionWindowJoinsAtWordOverlap() {
        let utterance = UtteranceState()
        _ = utterance.observe("Ara should insert this whole message")

        XCTAssertEqual(
            utterance.observe("whole message into the active field"),
            "Ara should insert this whole message into the active field"
        )
    }

    func testRecognitionCorrectionFromStartRemainsAuthoritative() {
        let utterance = UtteranceState()
        _ = utterance.observe("Ara should inert the message")

        XCTAssertEqual(
            utterance.observe("Ara should insert the message"),
            "Ara should insert the message"
        )
    }
}
