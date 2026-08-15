import XCTest

final class PasteDeliveryPolicyTests: XCTestCase {
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

    /// 手动粘贴路径默认永不还原（0 / 负值 → nil）；只有用户选了档位才还原。
    func testManualRestoreDelayOnlyAppliesWhenRetentionConfigured() {
        XCTAssertNil(PasteDeliveryPolicy.manualRestoreDelay(retentionSeconds: 0))
        XCTAssertNil(PasteDeliveryPolicy.manualRestoreDelay(retentionSeconds: -5))
        XCTAssertEqual(PasteDeliveryPolicy.manualRestoreDelay(retentionSeconds: 15), 15)
    }

    /// 设置页档位：首项必须是"永不还原"（0），档位不给过短窗口。
    func testClipboardRetentionOptionsStartWithNeverRestore() {
        XCTAssertEqual(PasteDeliveryPolicy.clipboardRetentionOptions, [0, 15, 30, 60])
    }
}
