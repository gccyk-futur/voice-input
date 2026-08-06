import XCTest

final class PasteDeliveryPolicyTests: XCTestCase {
    func testAppStoreStillAttemptsAutomaticInsertionOnSupportedMacOSVersions() {
        XCTAssertEqual(PasteDeliveryPolicy.mode(isAppStore: true), .automatic)
    }

    func testDirectBuildCanUseAutomaticInsertion() {
        XCTAssertEqual(PasteDeliveryPolicy.mode(isAppStore: false), .automatic)
    }

    func testAutomaticAttemptKeepsClipboardAvailableForManualFallback() {
        XCTAssertEqual(PasteDeliveryPolicy.clipboardFallbackWindow, 8.0)
    }

    func testPostEventAccessMustBeGrantedBeforeAutomaticInsertion() {
        XCTAssertEqual(
            PasteDeliveryPolicy.postEventDecision(preflightGranted: true, requestGranted: false),
            .automatic
        )
        XCTAssertEqual(
            PasteDeliveryPolicy.postEventDecision(preflightGranted: false, requestGranted: true),
            .automatic
        )
        XCTAssertEqual(
            PasteDeliveryPolicy.postEventDecision(preflightGranted: false, requestGranted: false),
            .clipboardOnly
        )
    }
}
