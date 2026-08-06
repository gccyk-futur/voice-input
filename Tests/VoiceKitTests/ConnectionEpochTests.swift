import XCTest

final class ConnectionEpochTests: XCTestCase {
    func testNewConnectionMakesPreviousCallbacksStale() {
        var epochs = ConnectionEpoch()
        let first = epochs.begin()
        let second = epochs.begin()

        XCTAssertFalse(epochs.accepts(first))
        XCTAssertTrue(epochs.accepts(second))
    }

    func testStaleInvalidationDoesNotInvalidateCurrentConnection() {
        var epochs = ConnectionEpoch()
        let first = epochs.begin()
        let second = epochs.begin()

        epochs.invalidate(first)

        XCTAssertTrue(epochs.accepts(second))
        XCTAssertFalse(epochs.accepts(first))
    }
}
