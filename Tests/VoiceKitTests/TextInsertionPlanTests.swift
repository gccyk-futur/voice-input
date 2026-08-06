import XCTest

final class TextInsertionPlanTests: XCTestCase {
    func testReplacesSelectedUTF16RangeAndPlacesCaretAfterInsertedText() {
        let plan = TextInsertionPlan.make(
            currentValue: "prefix suffix",
            selectedRange: NSRange(location: 7, length: 6),
            insertion: "新"
        )

        XCTAssertEqual(plan?.replacement, "prefix 新")
        XCTAssertEqual(plan?.caretLocation, 8)
    }

    func testRejectsRangeOutsideCurrentValue() {
        XCTAssertNil(TextInsertionPlan.make(
            currentValue: "short",
            selectedRange: NSRange(location: 99, length: 0),
            insertion: "text"
        ))
    }
}
