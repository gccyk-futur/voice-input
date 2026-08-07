import XCTest

final class VoiceKitUIStateTests: XCTestCase {
    func testTextScalePresetsHaveStableReadableMultipliers() {
        XCTAssertEqual(VoiceKitTextScale.system.multiplier, 1.0)
        XCTAssertEqual(VoiceKitTextScale.large.multiplier, 1.15)
        XCTAssertEqual(VoiceKitTextScale.extraLarge.multiplier, 1.30)
        XCTAssertEqual(VoiceKitTextScale.allCases.map(\.title), ["跟随系统", "较大", "更大"])
        XCTAssertEqual(VoiceKitTextScale.restored(from: "large"), .large)
        XCTAssertEqual(VoiceKitTextScale.restored(from: "removed-scale"), .system)
    }

    func testAppearancePresetsFollowSystemOrForceATheme() {
        XCTAssertEqual(VoiceKitAppearance.allCases.map(\.title), ["跟随系统", "浅色", "深色"])
        XCTAssertEqual(VoiceKitAppearance.restored(from: "dark"), .dark)
        XCTAssertEqual(VoiceKitAppearance.restored(from: "removed-appearance"), .system)
    }

    func testDirectDistributionExplainsAccessibilityAndClipboardFallback() {
        let presentation = WriteBackPresentation.make(
            distribution: .direct,
            permission: .denied
        )

        XCTAssertEqual(presentation.title, "辅助功能（直接写入）")
        XCTAssertTrue(presentation.explanation.contains("直接访问目标输入框"))
        XCTAssertTrue(presentation.fallbackExplanation.contains("剪贴板"))
        XCTAssertTrue(presentation.fallbackExplanation.contains("⌘V"))
    }

    func testAppStoreDistributionExplainsAttemptAndManualFallback() {
        let presentation = WriteBackPresentation.make(
            distribution: .appStore,
            permission: .granted
        )

        XCTAssertEqual(presentation.title, "自动写回（键盘事件）")
        XCTAssertTrue(presentation.explanation.contains("尝试自动写回"))
        XCTAssertTrue(presentation.explanation.contains("沙盒"))
        XCTAssertTrue(presentation.fallbackExplanation.contains("手动按 ⌘V"))
    }

    func testSettingsPanesUseStableHIGNavigationOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), [
            "常规", "语音引擎", "AI 服务", "模型管理", "提示词管理", "权限", "数据隐私", "关于"
        ])
        XCTAssertEqual(SettingsPane.models.systemImage, "cube")
        XCTAssertEqual(SettingsPane.permissions.index, 5)
        XCTAssertTrue(SettingsPane.allCases.allSatisfy { !$0.description.isEmpty })
    }

    func testSettingsPaneRestoresKnownValueAndFallsBackSafely() {
        XCTAssertEqual(SettingsPane.restored(from: "permissions"), .permissions)
        XCTAssertEqual(SettingsPane.restored(from: "removed-pane"), .general)
    }

    func testOnlyDirectAccessibilityNeedsReloadAfterPermissionBecomesUsable() {
        XCTAssertEqual(
            VoiceKitPermissionReloadState.make(
                distribution: .direct,
                permission: .granted,
                requested: true
            ),
            .recommended
        )
        XCTAssertEqual(
            VoiceKitPermissionReloadState.make(
                distribution: .appStore,
                permission: .granted,
                requested: true
            ),
            .hidden
        )
    }
}
