import AppKit
import SwiftUI

/// 轻量吐司通知：独立于听写面板的无边框浮窗。
/// 用于一次性状态提示（如「已复制到剪贴板，请按 ⌘V」）——
/// 不抢焦点、不响应鼠标、淡入后停留数秒自动淡出消散。
@MainActor
final class ToastController {
    static let shared = ToastController()

    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var appearanceApplier: AppearanceApplier?

    /// 展示一条吐司；重复调用会替换旧吐司并重置计时。
    func show(_ message: String, duration: TimeInterval = 4) {
        hideTask?.cancel()
        let toast = makeWindow(message: message)
        positionNearBottom(toast)

        toast.alphaValue = 0
        toast.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            toast.animator().alphaValue = 1
        }

        hideTask = Task { [weak self, weak toast] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fadeOut(toast)
        }
    }

    // MARK: - 私有

    private func fadeOut(_ toast: NSPanel?) {
        guard let toast else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            toast.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                toast.orderOut(nil)
                if self?.window === toast { self?.window = nil }
            }
        })
    }

    private func makeWindow(message: String) -> NSPanel {
        // 每次新建并丢弃旧窗口，避免旧文案/尺寸残留
        if let old = window {
            old.orderOut(nil)
            window = nil
        }

        let hosting = NSHostingView(rootView: ToastView(message: message))
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // 纯通知：鼠标事件穿透，绝不干扰用户正在输入的目标 App
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        hosting.translatesAutoresizingMaskIntoConstraints = false
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
        return panel
    }

    /// 屏幕下方居中（避开用户正在输入的屏幕中央区域）。
    private func positionNearBottom(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 110
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - 吐司内容

private struct ToastView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue

    let message: String

    private var textScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: textScale)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(typography.callout)
                .foregroundStyle(.tint)
            Text(message)
                .font(typography.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .voiceKitTextScale(textScale)
    }
}
