import XCTest

final class ASRTaskLifecycleTests: XCTestCase {
    func test_finishMustBeObservedBeforeNextTaskCanStart() {
        var lifecycle = ASRTaskLifecycle()

        XCTAssertEqual(lifecycle.begin(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.taskStarted(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.requestFinish(taskID: "a"), .accepted)
        XCTAssertFalse(lifecycle.canStart)
        XCTAssertEqual(lifecycle.begin(taskID: "b"), .rejected(.busy))

        XCTAssertEqual(lifecycle.taskFinished(taskID: "a"), .accepted)
        XCTAssertTrue(lifecycle.canStart)
    }

    func test_failedTaskInvalidatesConnectionAndDoesNotPermitImmediateReuse() {
        var lifecycle = ASRTaskLifecycle()

        XCTAssertEqual(lifecycle.begin(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.taskStarted(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.taskFailed(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.begin(taskID: "b"), .rejected(.requiresReconnect))

        XCTAssertEqual(lifecycle.reconnectSucceeded(), .accepted)
        XCTAssertEqual(lifecycle.begin(taskID: "b"), .accepted)
    }

    func test_cancelDuringStartBlocksTheNextStartUntilTheOldTaskFinishes() {
        var lifecycle = ASRTaskLifecycle()

        XCTAssertEqual(lifecycle.begin(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.requestFinish(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.taskStarted(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.begin(taskID: "b"), .rejected(.busy))
        XCTAssertEqual(lifecycle.taskFinished(taskID: "a"), .accepted)
        XCTAssertEqual(lifecycle.begin(taskID: "b"), .accepted)
    }
}
