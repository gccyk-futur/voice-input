import AppKit
import SwiftUI

/// 速插浮层控制器：一个独立悬浮面板，用于「呼出即插」。
/// 显示时记录前台目标 App，插入后自动收起。
@MainActor
final class QuickInsertPanelController: NSObject {
    static let shared = QuickInsertPanelController()

    /// 键盘动作转发给 SwiftUI 视图：object 为 Int，-1 上移、+1 下移、2 插入选中项。
    static let keyActionNotification = Notification.Name("QuickInsertKeyAction")

    private(set) var window: NSPanel?
    private var appearanceApplier: AppearanceApplier?
    private var keyMonitor: Any?

    /// 打开浮层前的最后一个前台应用（速插写回目标）。
    private(set) var previousFrontmostApp: NSRunningApplication?

    func toggle() {
        if let win = window, win.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = front
        }

        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        // 仿转录面板：隐藏红绿灯，仅保留 ✕ 关闭
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // 仿转录面板：NSVisualEffectView 毛玻璃质感
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: QuickInsertView())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.safeAreaRegions = []

        panel.contentView = effect
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        appearanceApplier = AppearanceApplier(window: panel)
        window = panel

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        window?.orderOut(nil)
    }

    // Esc 关闭、↑↓ 移动选中、↵ 插入、Tab 切换标签（转发给 QuickInsertView）。本地监听先于
    // 文本框拿到事件，因此搜索框聚焦时这些键也不会被文本编辑吞掉。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: // Esc
                self?.close()
                return nil
            case 126: // ↑
                NotificationCenter.default.post(name: Self.keyActionNotification, object: -1)
                return nil
            case 125: // ↓
                NotificationCenter.default.post(name: Self.keyActionNotification, object: 1)
                return nil
            case 36, 76: // Return / 小键盘 Enter
                NotificationCenter.default.post(name: Self.keyActionNotification, object: 2)
                return nil
            case 48: // Tab：切换标签（⇧Tab 反向）
                NotificationCenter.default.post(
                    name: Self.keyActionNotification,
                    object: event.modifierFlags.contains(.shift) ? 4 : 3
                )
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
