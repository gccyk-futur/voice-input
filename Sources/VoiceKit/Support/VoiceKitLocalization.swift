import Foundation

/// Centralizes plain `String` localization for AppKit, coordinator, and model code.
/// SwiftUI literals continue to use the system's `LocalizedStringKey` behavior.
enum VoiceKitLocalization {
    static func string(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: key,
            comment: ""
        )
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
