import XCTest

final class AudioSendDrainTests: XCTestCase {
    func test_waitReturnsOnlyAfterAllRegisteredSendsEnd() async {
        let drain = AudioSendDrain()
        XCTAssertTrue(drain.begin())
        XCTAssertTrue(drain.begin())
        drain.close()
        XCTAssertFalse(drain.begin())

        let waiter = Task {
            await drain.wait()
            return true
        }

        await Task.yield()
        drain.end()
        XCTAssertFalse(waiter.isCancelled)

        drain.end()
        let completed = await waiter.value
        XCTAssertTrue(completed)
    }
}
