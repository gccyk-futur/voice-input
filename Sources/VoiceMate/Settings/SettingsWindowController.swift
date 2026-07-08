import AppKit
import SwiftUI

/// 设置窗口控制器：复用单个窗口实例。
/// Surge 风格的行为：
/// - 显示窗口 → 切到 .regular 策略（出现在 Dock/Cmd+Tab，可被双击唤醒）
/// - 关闭窗口 → 切回 .accessory 策略（Dock/Cmd+Tab 消失），app 不退出
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?

    func show() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoiceMate 设置"
        win.contentView = NSHostingView(rootView: SettingsView(onDone: { [weak self] in self?.close() }))
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关闭窗口时不退出 app，只是隐藏
        win.delegate = self
        window = win

        showWindow(win)
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
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        print("[SettingsWindow] 窗口关闭 → 切回 accessory 策略，app 继续运行")
        // 窗口关闭后切回 accessory，从 Dock/Switcher 消失
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 窗口被激活时确保策略是 .regular（双击唤醒时用到）
        NSApp.setActivationPolicy(.regular)
    }
}
