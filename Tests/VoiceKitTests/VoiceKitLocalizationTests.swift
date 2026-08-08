import XCTest

final class VoiceKitLocalizationTests: XCTestCase {
    func testMissingLocalizationFallsBackToItsSourceKey() {
        XCTAssertEqual(VoiceKitLocalization.string("missing.localization.key"), "missing.localization.key")
    }

    func testLocalizedFormatPreservesRuntimeArguments() {
        XCTAssertEqual(
            VoiceKitLocalization.format("测试 %@：%lld", "状态", 3),
            "测试 状态：3"
        )
    }
}
