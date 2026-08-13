import AppKit
import SwiftUI

/// 设置窗口与 SwiftUI 视图之间的状态桥：
/// 红叉/Cmd+W 关闭请求被 windowShouldClose 拦截后，由 SwiftUI 侧弹「放弃更改」确认。
@MainActor
final class SettingsWindowBridge {
    /// SwiftUI 侧 draft 与原始配置存在差异
    var hasChanges = false
    /// 控制器请求 SwiftUI 侧弹出「放弃更改」确认
    var discardConfirmationRequested = false
}

/// 设置窗口控制器：复用单个窗口实例。
/// - 使用稳定的侧边栏导航，切换页面不改变窗口尺寸
/// - 关闭窗口时切回 .accessory 策略
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?
    private var appearanceApplier: AppearanceApplier?
    private var bridge = SettingsWindowBridge()

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
        win.title = VoiceKitLocalization.string("VoiceKit 设置")
        // 先登记窗口，再安装 SwiftUI 内容，确保 rootView 的 onAppear
        // 恢复上次面板时能够立即更新窗口标题。
        window = win
        bridge = SettingsWindowBridge()
        win.contentView = NSHostingView(rootView: SettingsView(bridge: bridge,
                                                               onDone: { [weak self] in self?.close() },
                                                               onTabChange: { [weak self] tab in self?.updateTitle(for: tab) }))
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Surge 式无边标题栏：内容延伸到窗口顶部，侧栏底灰透到红绿灯区域，
        // 标题文字隐藏（各面板自带标题）。SwiftUI 根视图遵守安全区，
        // 侧栏首行不会被红绿灯遮挡。
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // 与 SwiftUI 根视图的 .frame(minWidth: 760, minHeight: 520) 保持一致：
        // 此前 720×480 与内容最小尺寸冲突，Auto Layout 约束打架导致切换页面时版式错乱。
        win.minSize = NSSize(width: 760, height: 520)
        // 外观在窗口层应用：侧栏与 detail 同步渲染，跟随系统时系统切换自动生效
        appearanceApplier = AppearanceApplier(window: win)
        // 关闭窗口时不退出 app，只是隐藏
        win.delegate = self

        win.setContentSize(NSSize(width: 820, height: 580))

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

    private func updateTitle(for tab: Int) {
        // 页面标题由右侧内容区展示，窗口标题保持稳定，符合 macOS 设置窗口
        // 的导航模型，也避免切换侧边栏时出现重复标题。
        guard let win = window else { return }
        win.title = VoiceKitLocalization.string("VoiceKit 设置")
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    /// 拦截红叉/Cmd+W 的真实关闭：统一走 handleCloseRequest，
    /// 有未保存变更时弹「放弃更改」确认（此前红叉会静默丢弃修改）。
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor [weak self] in self?.handleCloseRequest() }
        return false
    }

    private func handleCloseRequest() {
        if bridge.hasChanges {
            bridge.discardConfirmationRequested = true
        } else {
            close()
        }
    }

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
        }
    }
}
