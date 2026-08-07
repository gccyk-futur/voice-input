import AppKit
import SwiftUI

/// 设置窗口控制器：复用单个窗口实例。
/// - 使用稳定的侧边栏导航，切换页面不改变窗口尺寸
/// - 关闭窗口时切回 .accessory 策略
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?
    private var appearanceApplier: AppearanceApplier?

    func show() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoiceKit 设置"
        // 先登记窗口，再安装 SwiftUI 内容，确保 rootView 的 onAppear
        // 恢复上次面板时能够立即更新窗口标题。
        window = win
        win.contentView = NSHostingView(rootView: SettingsView(onDone: { [weak self] in self?.close() },
                                                               onTabChange: { [weak self] tab in self?.updateTitle(for: tab) }))
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 720, height: 480)
        // 外观在窗口层应用：侧栏与 detail 同步渲染，跟随系统时系统切换自动生效
        appearanceApplier = AppearanceApplier(window: win)
        // 关闭窗口时不退出 app，只是隐藏
        win.delegate = self

        win.setContentSize(NSSize(width: 820, height: 580))

        showWindow(win)
        removeSidebarToggle(from: win)
    }

    /// macOS 26 上 SwiftUI 的 .toolbar(removing: .sidebarToggle) 不生效，
    /// 直接从 NSToolbar 移除 NavigationSplitView 的侧栏折叠按钮。
    private func removeSidebarToggle(from win: NSWindow) {
        guard let toolbar = win.toolbar else { return }
        for (index, item) in toolbar.items.enumerated().reversed()
        where item.itemIdentifier.rawValue.lowercased().contains("togglesidebar") {
            toolbar.removeItem(at: index)
        }
    }

    /// 显示窗口：切到 .regular 让 app 出现在 Dock/Switcher
    private func showWindow(_ win: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭（隐藏）窗口：切回 .accessory，Dock/Switcher 消失，app 不退出
    func close() {
        guard let win = window, win.isVisible else { return }
        win.orderOut(nil)
        // macOS 14: 立即切 .accessory 可能导致 MenuBarExtra 图标消失，
        // 延迟一帧让系统完成窗口关闭动画再切换策略。
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func updateTitle(for tab: Int) {
        // 页面标题由右侧内容区展示，窗口标题保持稳定，符合 macOS 设置窗口
        // 的导航模型，也避免切换侧边栏时出现重复标题。
        guard let win = window else { return }
        win.title = "VoiceKit 设置"
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            print("[SettingsWindow] 窗口关闭 → 切回 accessory 策略，app 继续运行")
            // 窗口关闭后切回 accessory，从 Dock/Switcher 消失
            NSApp.setActivationPolicy(.accessory)
        }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            // 窗口被激活时确保策略是 .regular（双击唤醒时用到）
            NSApp.setActivationPolicy(.regular)
            // toolbar 项目可能延迟出现，激活时再清一次侧栏折叠按钮
            if let win = self.window { self.removeSidebarToggle(from: win) }
        }
    }
}
