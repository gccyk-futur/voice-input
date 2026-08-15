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

    /// 设置页可选的识别文字保留时长（秒）；0 = 永不还原（等同普通复制）。
    static let clipboardRetentionOptions: [Double] = [0, 15, 30, 60]

    /// 手动粘贴路径（writeClipboardOnly）的剪贴板还原延迟；nil 表示永不还原。
    /// 与 paste() 的固定借用还原（clipboardFallbackWindow）是两回事：这里还原
    /// 会让识别文字从剪贴板消失，窗口必须覆盖用户手动 ⌘V 的反应时间，
    /// 因此只接受设置页给出的档位，不允许任意小值。
    static func manualRestoreDelay(retentionSeconds: Double) -> TimeInterval? {
        retentionSeconds > 0 ? retentionSeconds : nil
    }
}
