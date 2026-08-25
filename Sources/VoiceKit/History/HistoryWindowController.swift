import AppKit
import SwiftUI

/// 历史记录窗口控制器：复用单个窗口实例。
/// 窗口显示时切到 .regular（出现在 Dock/Switcher），关闭时切回 .accessory。
@MainActor
final class HistoryWindowController: NSObject {
    static let shared = HistoryWindowController()

    private(set) var window: NSWindow?
    private var appearanceApplier: AppearanceApplier?

    /// 打开历史窗口前的最后一个前台应用（供「重新粘贴」写回用）。
    private(set) var previousFrontmostApp: NSRunningApplication?

    func show() {
        // 记录前台目标：排除自己，得到用户打开历史前的那个 App。
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = front
        }

        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let win = window {
            // 复用窗口但重建内容视图：AppKit 关窗时会清掉 List 的选中高亮且无法用 binding 唤回，
            // 重建后 HistoryView.onAppear 从 lastTabRaw 恢复选中，侧栏高亮与内容区重新一致
            win.contentView = NSHostingView(rootView: HistoryView())
            showWindow(win)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = VoiceKitLocalization.string("VoiceKit 历史")
        win.contentView = NSHostingView(rootView: HistoryView())
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 固定居中打开：frame 自动保存与 SwiftUI ideal 尺寸会互相拉扯导致落点漂移，
        // 故不做位置记忆；窗口对象复用，本次运行内后续打开仍保持上次位置。
        win.center()
        win.delegate = self
        appearanceApplier = AppearanceApplier(window: win)
        window = win

        showWindow(win)
    }

    private func showWindow(_ win: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let win = window, win.isVisible else { return }
        win.orderOut(nil)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - NSWindowDelegate

extension HistoryWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            print("[HistoryWindow] 窗口关闭 → 切回 accessory 策略")
            NSApp.setActivationPolicy(.accessory)
        }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
        }
    }
}
