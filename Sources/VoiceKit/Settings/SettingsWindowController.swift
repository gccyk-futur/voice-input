import AppKit
import SwiftUI

/// 设置窗口控制器：复用单个窗口实例。
/// - 切换标签时自动调整窗口高度（带动画）
/// - 关闭窗口时切回 .accessory 策略
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?

    /// 各标签的理想窗口高度
    private static let tabHeights: [CGFloat] = [
        500,  // 常规
        500,  // 语音识别
        500,  // AI 润色
        500,  // 权限
        500,  // 关于
    ]

    func show() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoiceKit 设置"
        win.contentView = NSHostingView(rootView: SettingsView(onDone: { [weak self] in self?.close() },
                                                               onTabChange: { [weak self] tab in self?.resizeToTab(tab) }))
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关闭窗口时不退出 app，只是隐藏
        win.delegate = self
        window = win

        // 强制内容区域为初始标签的高度（NSHostingView 的 intrinsic size 会撑大窗口）
        win.setContentSize(NSSize(width: 560, height: Self.tabHeights[0]))

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

    /// 切换标签时调整窗口高度（带动画）
    private func resizeToTab(_ tab: Int) {
        guard let win = window, tab < Self.tabHeights.count else { return }
        var size = win.contentRect(forFrameRect: win.frame).size
        size.height = Self.tabHeights[tab]
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().setContentSize(size)
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
