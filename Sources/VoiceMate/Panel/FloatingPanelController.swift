import AppKit
import SwiftUI

/// 悬浮面板控制器：NSPanel（nonactivating）+ NSVisualEffectView 毛玻璃背景。
/// 遵循 HIG：不抢焦点、可被 Esc/取消关闭；毛玻璃材质本身由系统适配「降低透明度」。
@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private weak var coordinator: AppCoordinator?
    private var keyMonitor: Any?
    /// 必须持有强引用：NSWindow.delegate 是 weak 的，PanelDelegate 若无强引用会被立即释放，
    /// 导致 windowWillClose 从不触发（关闭面板不会调用 cancel）。
    private var panelDelegate: PanelDelegate?

    func setCoordinator(_ coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    var isKeyWindow: Bool { panel?.isKeyWindow ?? false }

    func makeKey() {
        panel?.makeKey()
    }

    /// 将面板提到最前并设为 key window。
    func orderFront() {
        panel?.makeKeyAndOrderFront(nil)
    }

    /// 向自己的 panel 发送一次模拟鼠标点击（不移动真实光标）。事件通过 postToPid 直送本进程，
    /// AppKit 处理时会检测到 app 未激活 → 自动触发 NSApp.activate，产生与用户手动点击面板
    /// 完全相同的 WindowServer 激活链。这是使得 DictationTranscriber 开始处理音频的关键。
    func clickToActivate() {
        guard let panel else { return }
        let frame = panel.frame
        let clickPoint = CGPoint(x: frame.midX, y: frame.midY)
        let pid = ProcessInfo.processInfo.processIdentifier

        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                  mouseCursorPosition: clickPoint, mouseButton: .left),
              let up   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                  mouseCursorPosition: clickPoint, mouseButton: .left) else {
            print("[Panel] clickToActivate: failed to create CGEvent")
            return
        }
        down.postToPid(pid)
        usleep(10_000)
        up.postToPid(pid)
        print("[Panel] clickToActivate posted, pid=\(pid), point=\(clickPoint)")
    }

    func show(needsActivation: Bool = false) {
        if panel == nil { buildPanel() }
        // .nonactivatingPanel 保证面板浮在最前且可接收键盘事件，但不激活 App。
        // 目标 App 始终保持前台，无需来回切换焦点。
        // needsActivation=true 时额外触发激活（仅 DictationTranscriber 引擎需此行为）。
        panel?.center()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if needsActivation {
            // 轻量激活：激活 App 但不隐藏其他 App 窗口（与 ignoringOtherApps: true 不同）
            NSApp.activate(ignoringOtherApps: false)
            clickToActivate()
        }
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - 构建

    private func buildPanel() {
        guard let coordinator else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        let pdl = PanelDelegate { [weak self] in
            Task { @MainActor in self?.coordinator?.cancel() }
        }
        panel.delegate = pdl
        panelDelegate = pdl

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: PanelView().environment(coordinator))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = effect
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        self.panel = panel
    }

    // MARK: - 键盘（Cmd+Return 粘贴 / Esc 取消）

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.keyCode == 36 { // Return
                self?.coordinator?.confirmPaste()
                return nil
            }
            if event.keyCode == 53 { // Esc
                self?.coordinator?.cancel()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        print("[Panel] windowWillClose → cancel")
        onClose()
    }
}
