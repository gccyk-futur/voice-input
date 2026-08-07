import XCTest

final class AudioPreRollSendGateTests: XCTestCase {
    func test_serverReadyFlushesBufferedAudioBeforeLiveAudio() async {
        let sent = DataCollector()
        let sendQueue = DispatchQueue(label: "AudioPreRollSendGateTests.send")
        let gate = AudioPreRollSendGate(sendQueue: sendQueue) { data in
            sent.append(data)
        }
        let first = Data([1])
        let second = Data([2, 3])
        let live = Data([4])

        XCTAssertEqual(gate.append(first), .buffered(totalBytes: 1))
        XCTAssertEqual(gate.append(second), .buffered(totalBytes: 3))
        XCTAssertEqual(sent.values, [])

        let firstReady = await gate.serverReady()
        XCTAssertTrue(firstReady)
        XCTAssertEqual(gate.append(live), .live)
        sendQueue.sync {}

        XCTAssertEqual(sent.values, [first, second, live])
    }

    func test_serverReadyIsOneShotAndDiscardRejectsLateAudio() async {
        let sent = DataCollector()
        let sendQueue = DispatchQueue(label: "AudioPreRollSendGateTests.send")
        let gate = AudioPreRollSendGate(sendQueue: sendQueue) { data in
            sent.append(data)
        }

        XCTAssertEqual(gate.append(Data([1])), .buffered(totalBytes: 1))
        let firstReady = await gate.serverReady()
        let secondReady = await gate.serverReady()
        XCTAssertTrue(firstReady)
        XCTAssertFalse(secondReady)

        gate.discard()
        XCTAssertEqual(gate.append(Data([2])), .discarded)
        sendQueue.sync {}
        XCTAssertEqual(sent.values, [Data([1])])
    }

    func test_discardBeforeServerReadySendsNothing() async {
        let sent = DataCollector()
        let sendQueue = DispatchQueue(label: "AudioPreRollSendGateTests.send")
        let gate = AudioPreRollSendGate(sendQueue: sendQueue) { data in
            sent.append(data)
        }

        XCTAssertEqual(gate.append(Data([1, 2])), .buffered(totalBytes: 2))
        gate.discard()

        let ready = await gate.serverReady()
        XCTAssertFalse(ready)
        sendQueue.sync {}
        XCTAssertEqual(sent.values, [])
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }
}
