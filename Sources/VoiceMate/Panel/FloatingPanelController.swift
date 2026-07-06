import AppKit
import SwiftUI

/// 悬浮面板控制器：NSPanel（nonactivating）+ NSVisualEffectView 毛玻璃背景。
/// 遵循 HIG：不抢焦点、可被 Esc/取消关闭；毛玻璃材质本身由系统适配「降低透明度」。
@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private weak var coordinator: AppCoordinator?
    private var keyMonitor: Any?

    func setCoordinator(_ coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if panel == nil { buildPanel() }
        panel?.center()
        // 必须让面板成为 key window，本 app 才会真正激活——on-device 听写 daemon 只在
        // 本 app 为激活态时才回传结果（否则必须手动点面板才开始识别）。停止时会把焦点
        // 还给目标 app，因此此处抢焦点是安全的。
        panel?.orderFrontRegardless()
        panel?.makeKey()
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = PanelDelegate { [weak self] in
            Task { @MainActor in self?.coordinator?.cancel() }
        }

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
    func windowWillClose(_ notification: Notification) { onClose() }
}
