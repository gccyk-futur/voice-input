import AppKit
import SwiftUI

/// 应用代理：使用 AppKit 原生 NSStatusItem + NSPopover 管理菜单栏图标，
/// 替代 SwiftUI 的 MenuBarExtra（后者在 SystemUIServer 重启 / 内存压力
/// / notch 隐藏等场景下会静默消失且无法自愈）。
///
/// 策略：
/// - 启动时创建 NSStatusItem 强引用（AppDelegate 持有，永不释放）
/// - NSPopover 内嵌 StatusBarMenuView，视觉与 MenuBarExtra(.window) 一致
/// - 每 5 秒巡检图标可见性，消失自动重建
/// - 监听唤醒/Space切换/分辨率变化事件立即检查恢复
/// - .accessory 策略：无 Dock、不出现 Cmd+Tab
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var monitorTimer: Timer?
    private var eventShow: AnyObject?

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        startMonitoring()
        observeSystemEvents()

        let coordinator = AppCoordinator.shared
        syncLoginItem()

        Task { @MainActor in
            if ConfigStore.shared.config.asr.engine == "aliyun" {
                await coordinator.prewarmAliyunEngine()
            }
        }

        if ConfigStore.shared.config.general.showSettingsOnLaunch {
            SettingsWindowController.shared.show()
        }
    }

    // MARK: - NSStatusItem

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceMate")
        button.action = #selector(togglePopover)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 重建状态栏图标（SystemUIServer 重启等场景后调用）
    private func rebuildStatusItem() {
        print("[AppDelegate] 检测到图标消失，重建 NSStatusItem")
        // 先移除旧的（如果有），避免泄漏
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
            statusItem = nil
        }
        setupStatusItem()
    }

    /// 巡检：图标是否还活着。
    /// button.window == nil → SystemUIServer 已移除该图标 → 重建。
    private func checkAndRestoreStatusItem() {
        guard let button = statusItem?.button else {
            rebuildStatusItem()
            return
        }
        if button.window == nil {
            rebuildStatusItem()
        }
    }

    // MARK: - NSPopover

    private func setupPopover() {
        popover.contentViewController = NSHostingController(rootView: StatusBarMenuView()
            .frame(minWidth: 260, maxHeight: 460))
        popover.behavior = .transient // 点击外部自动关闭，标准菜单栏 App 行为
        popover.animates = true
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 确保 popover 成为 key window，否则文本选择等交互失效
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 供外部（如 StatusBarMenuView 底部按钮）关闭 popover
    func dismissPopover() {
        if popover.isShown {
            popover.close()
        }
    }

    // MARK: - 定时巡检

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAndRestoreStatusItem()
            }
        }
        // 允许 timer 在 popover 打开时仍然运行
        if let timer = monitorTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    // MARK: - 系统事件监听

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleSystemEvent),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemEvent),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleSystemEvent),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// 延迟 0.5s 后再检查——系统事件触发时菜单栏可能还没完成重排
    @objc private func handleSystemEvent() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkAndRestoreStatusItem()
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

    // MARK: - 双击唤醒

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
