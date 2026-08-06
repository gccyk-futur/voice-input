import XCTest

final class AudioTapFormatPolicyTests: XCTestCase {
    func testTapUsesNodeOutputFormatSoRouteChangesCannotForceAFormatMismatch() {
        XCTAssertTrue(AudioTapFormatPolicy.usesNodeOutputFormat)
    }
}
