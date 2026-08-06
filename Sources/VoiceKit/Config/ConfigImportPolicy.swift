import Foundation

enum ConfigImportPolicy {
    static let supportedFileName = "config.json"

    static func legacyConfigURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VoiceMate", isDirectory: true)
            .appendingPathComponent(supportedFileName)
    }

    static func isSupportedImportURL(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare(supportedFileName) == .orderedSame
    }
}
