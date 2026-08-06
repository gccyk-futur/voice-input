import XCTest

final class ConfigImportPolicyTests: XCTestCase {
    func testLegacyConfigURLUsesTheOfficialApplicationSupportLocation() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            ConfigImportPolicy.legacyConfigURL(homeDirectory: home).path,
            "/Users/example/Library/Application Support/VoiceMate/config.json"
        )
    }

    func testOnlyConfigJSONIsAcceptedForImport() {
        XCTAssertTrue(ConfigImportPolicy.isSupportedImportURL(
            URL(fileURLWithPath: "/tmp/config.json")
        ))
        XCTAssertFalse(ConfigImportPolicy.isSupportedImportURL(
            URL(fileURLWithPath: "/tmp/history.json")
        ))
    }
}
