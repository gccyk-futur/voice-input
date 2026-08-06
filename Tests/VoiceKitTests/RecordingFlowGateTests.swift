import XCTest

final class RecordingFlowGateTests: XCTestCase {
    func test_invalidatingAResolutionRejectsItsLateCompletion() {
        var gate = RecordingFlowGate()
        let first = gate.begin()

        XCTAssertTrue(gate.accepts(first))
        gate.invalidate()

        XCTAssertFalse(gate.accepts(first))
    }

    func test_newResolutionGetsItsOwnGeneration() {
        var gate = RecordingFlowGate()
        let first = gate.begin()
        gate.invalidate()
        let second = gate.begin()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }
}
