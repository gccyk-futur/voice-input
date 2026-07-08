import AppKit
import SwiftUI

/// 历史记录窗口控制器：复用单个窗口实例。
/// 窗口显示时切到 .regular（出现在 Dock/Switcher），关闭时切回 .accessory。
@MainActor
final class HistoryWindowController: NSObject {
    static let shared = HistoryWindowController()

    private(set) var window: NSWindow?

    func show() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoiceMate 历史"
        win.contentView = NSHostingView(rootView: HistoryView())
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.delegate = self
        window = win

        showWindow(win)
    }

    private func showWindow(_ win: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        win.center()
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
    func windowWillClose(_ notification: Notification) {
        print("[HistoryWindow] 窗口关闭 → 切回 accessory 策略")
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
