import AppKit

/// 应用代理：菜单栏 Agent。
/// Surge 风格策略：
/// - 启动时 .accessory（无 Dock），菜单栏常驻
/// - 打开窗口时自动切 .regular（出现在 Dock/Switcher）
/// - 关闭窗口时自动切回 .accessory
/// - 双击 .app → 弹出设置窗口
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认 .accessory：无 Dock 图标、不在 Cmd+Tab 出现
        NSApp.setActivationPolicy(.accessory)

        _ = AppCoordinator.shared
        syncLoginItem()

        // 启动行为
        if ConfigStore.shared.config.general.showSettingsOnLaunch {
            SettingsWindowController.shared.show()
        }
    }

    // MARK: - 退出确认

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "退出 VoiceMate？"
        alert.informativeText = "退出后语音识别服务将停止运行，菜单栏图标也会消失。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - 双击唤醒（Surge 风格）

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        print("[AppDelegate] applicationShouldHandleReopen → 显示设置窗口")
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: - 登录项

    private func syncLoginItem() {
        LoginItemManager.set(enabled: ConfigStore.shared.config.general.launchAtStartup)
    }
}
