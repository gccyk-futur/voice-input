import AppKit
import SwiftUI

/// 设置窗口控制器：承载 SettingsView 的独立窗口。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        // 每次打开都重建视图，确保状态归零
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoiceMate 设置"
        win.contentView = NSHostingView(rootView: SettingsView(onDone: { [weak self] in self?.close() }))
        win.isReleasedWhenClosed = false
        window = win
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }
}
