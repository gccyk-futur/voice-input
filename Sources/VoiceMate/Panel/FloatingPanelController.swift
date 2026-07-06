import AppKit
import SwiftUI

/// 悬浮面板控制器：NSPanel（nonactivating）+ NSVisualEffectView 毛玻璃背景。
/// 遵循 HIG：不抢焦点、可被 Esc/取消关闭、降低透明度时回退为实色。
@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private weak var coordinator: AppCoordinator?
    private var effectView: NSVisualEffectView?
    private var keyMonitor: Any?
    private var reduceObserver: NSObjectProtocol?

    func setCoordinator(_ coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if panel == nil { buildPanel() }
        applyTransparencyMode()
        panel?.center()
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
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
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
        self.effectView = effect

        reduceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityReduceTransparencyDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyTransparencyMode() }
    }

    private func applyTransparencyMode() {
        let reduce = NSWorkspace.shared.accessibilityReduceTransparency
        effectView?.state = reduce ? .inactive : .active
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

    deinit {
        if let obs = reduceObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
