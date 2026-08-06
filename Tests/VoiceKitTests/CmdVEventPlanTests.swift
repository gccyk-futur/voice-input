import XCTest

final class CmdVEventPlanTests: XCTestCase {
    func test_commandVPlanUsesCompatibleFlaggedVSequence() {
        let plan = CmdVEventPlan()

        XCTAssertEqual(plan.events, [.vDown, .vUp])
        XCTAssertTrue(plan.isBalanced)
    }

    func test_planHasNoSyntheticCommandLifecycle() {
        let plan = CmdVEventPlan()

        XCTAssertEqual(plan.events.first, .vDown)
        XCTAssertEqual(plan.events.last, .vUp)
    }
}
