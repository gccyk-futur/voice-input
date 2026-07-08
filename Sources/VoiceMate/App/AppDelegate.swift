import AppKit

/// 应用代理：菜单栏 Agent（不进 Dock，Info.plist 已设 LSUIElement=true）。
/// 引擎/协调器的启动在 AppCoordinator 中完成（见 Coordinator/AppCoordinator.swift）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppCoordinator.shared
        syncLoginItem()

        // 根据配置决定是否启动时显示设置页面
        if ConfigStore.shared.config.general.showSettingsOnLaunch {
            SettingsWindowController.shared.show()
        }
    }

    /// 根据配置同步登录项（登录时启动开关）。
    private func syncLoginItem() {
        LoginItemManager.set(enabled: ConfigStore.shared.config.general.launchAtStartup)
    }
}
