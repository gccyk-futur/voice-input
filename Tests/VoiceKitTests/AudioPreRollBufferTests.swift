import XCTest

final class AudioPreRollBufferTests: XCTestCase {
    func test_appendAndDrainPreserveFIFOOrderAndByteCount() {
        let buffer = AudioPreRollBuffer(capacityBytes: 8)
        let first = Data([1, 2])
        let second = Data([3, 4, 5])

        XCTAssertEqual(buffer.append(first), .buffered(totalBytes: 2))
        XCTAssertEqual(buffer.append(second), .buffered(totalBytes: 5))
        XCTAssertEqual(buffer.bufferedByteCount, 5)

        XCTAssertEqual(buffer.beginDraining(), [first, second])
        XCTAssertEqual(buffer.bufferedByteCount, 0)
        XCTAssertTrue(buffer.finishDraining())
        XCTAssertEqual(buffer.phase, .live)
    }

    func test_capacityOverflowIsExplicitAndDoesNotSilentlyTruncate() {
        let buffer = AudioPreRollBuffer(capacityBytes: 4)
        let first = Data([1, 2, 3])

        XCTAssertEqual(buffer.append(first), .buffered(totalBytes: 3))
        XCTAssertEqual(
            buffer.append(Data([4, 5])),
            .overflow(capacityBytes: 4, attemptedBytes: 5)
        )
        XCTAssertEqual(buffer.beginDraining(), [first])
    }

    func test_drainIsOneShotAndLiveAudioIsNotBufferedAgain() {
        let buffer = AudioPreRollBuffer(capacityBytes: 8)
        let first = Data([1])
        let live = Data([2, 3])

        XCTAssertEqual(buffer.append(first), .buffered(totalBytes: 1))
        XCTAssertEqual(buffer.beginDraining(), [first])
        XCTAssertNil(buffer.beginDraining())
        XCTAssertTrue(buffer.finishDraining())
        XCTAssertEqual(buffer.append(live), .live)
        XCTAssertFalse(buffer.finishDraining())
    }

    func test_discardRejectsLateAudioAndCannotBeDrained() {
        let buffer = AudioPreRollBuffer(capacityBytes: 8)
        XCTAssertEqual(buffer.append(Data([1, 2])), .buffered(totalBytes: 2))

        buffer.discard()

        XCTAssertEqual(buffer.phase, .discarded)
        XCTAssertEqual(buffer.append(Data([3])), .discarded)
        XCTAssertNil(buffer.beginDraining())
        XCTAssertFalse(buffer.finishDraining())
    }
}
