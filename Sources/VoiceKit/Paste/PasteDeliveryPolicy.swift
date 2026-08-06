enum PasteDeliveryMode: Equatable {
    case automatic
    case clipboardOnly
}

enum PasteDeliveryPolicy {
    /// `CGEvent.postToPid` only confirms that an event was dispatched. It does
    /// not confirm that the target control accepted the paste, so preserve the
    /// recognized text long enough for the user to press ⌘V manually.
    static let clipboardFallbackWindow: TimeInterval = 8.0

    static func postEventDecision(
        preflightGranted: Bool,
        requestGranted: Bool
    ) -> PasteDeliveryMode {
        preflightGranted || requestGranted ? .automatic : .clipboardOnly
    }

    static func mode(isAppStore: Bool) -> PasteDeliveryMode {
        // The channel build previously used the same postToPid delivery path
        // as the direct build. Keep that behavior; clipboard-only remains a
        // fallback mode for a future, explicitly detected failure.
        .automatic
    }
}
