import SwiftUI
import AppKit

/// 轻量设计令牌与共享组件：历史窗口、快照管理、速插浮层共用同一套视觉语言。
/// 只收敛视觉（间距 / 圆角 / 按钮 / 材质），不涉及业务逻辑。
enum VoiceKitDesign {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
    }

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 8
    }

    /// 渠道 + 版本行，例如「官网版 1.1.0 (1026)」/「App Store 1.1.0 (58)」。
    /// 用于浮层面板的底栏品牌位，让用户确认自己跑的是哪个包。
    static var versionLine: String {
        let info = Bundle.main
        let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
#if APP_STORE
        let channel = "App Store"
#else
        let channel = VoiceKitLocalization.string("官网版")
#endif
        return "\(channel) \(version) (\(build))"
    }
}

/// 行内操作图标按钮：统一 26×22 命中区、次要色、悬浮底板反馈。
/// 注意：按钮整排常显（不做悬停才出现），悬浮只是反馈，不改变可见性。
struct VoiceKitActionButton: View {
    let systemImage: String
    let help: String
    var destructive = false
    let action: () -> Void

    @State private var hovering = false

    private var foreground: Color {
        if destructive { return hovering ? .red : .red.opacity(0.75) }
        return hovering ? .primary : .secondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .voiceKitToolTip(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 与 VoiceKitActionButton 同观的菜单按钮（用于「导出」这类弹出菜单）：
/// 普通 Menu 没有悬浮底板反馈，视觉上与其他操作按钮不统一，这里补齐。
struct VoiceKitActionMenu<Content: View>: View {
    let systemImage: String
    let help: String
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .voiceKitToolTip(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 原生侧栏材质（NSVisualEffectView .sidebar）。与设置窗口一致：
/// withinWindow 混合（不透桌面、不受壁纸影响），跟随窗口激活态。
struct VoiceKitSidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 悬浮提示兜底：SwiftUI `.help()` 在部分 macOS 版本/窗口里不弹 tooltip，
/// 直接在内容背后垫一个设置了 toolTip 的 NSView，任何窗口里都可靠。
private struct VoiceKitToolTipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    func voiceKitToolTip(_ text: String) -> some View {
        background(VoiceKitToolTipView(text: text))
    }

    /// 浮层卡片：圆角 + 细描边。用于状态栏 popover 等毛玻璃容器上的内容分区。
    /// 填充不用纯白（.background）：浅色模式下白卡贴在毛玻璃灰底上对比太冲，
    /// 用 controlBackgroundColor 降透明度，与底色柔和融合、深浅模式都自适应。
    func voiceKitCard() -> some View {
        self
            .padding(10)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
            )
    }
}

/// 工具行搜索胶囊：三个历史标签共用，保证切换时宽度/样式不漂移。
struct VoiceKitSearchField: View {
    /// 调用方传入已本地化的占位串（VoiceKitLocalization.string(...)）。
    let placeholder: String
    @Binding var text: String
    var minWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: minWidth, maxWidth: .infinity)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
