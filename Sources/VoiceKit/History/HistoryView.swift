import SwiftUI
import AppKit

/// 历史窗口容器：与设置窗口同一版式——悬浮圆角侧栏（List .sidebar 样式 + 系统 .sidebar 材质）
/// + 白色圆角内容卡片（macOS 26 Finder 版式）。
/// 侧栏固定宽度，内容区稳定 → 切换标签不漂移；记住上次选中的标签。
@MainActor
struct HistoryView: View {
    @AppStorage("voicekit.history.lastTab") private var lastTabRaw = HistoryTab.all.rawValue
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var tab: HistoryTab?
    @State private var historyItems: [HistoryItem] = HistoryStore.shared.items
    @State private var snapshotCount = SnapshotStore.shared.items.count

    private var textScale: VoiceKitTextScale { VoiceKitTextScale.restored(from: textScaleRawValue) }
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }
    private var currentTab: HistoryTab { tab ?? .all }

    private enum HistoryTab: String, CaseIterable, Identifiable {
        case all, favorites, snapshots
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return VoiceKitLocalization.string("全部")
            case .favorites: return VoiceKitLocalization.string("收藏")
            case .snapshots: return VoiceKitLocalization.string("快照")
            }
        }
        var icon: String {
            switch self {
            case .all: return "clock"
            case .favorites: return "star"
            case .snapshots: return "square.and.arrow.down.on.square"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
            content
                // 内容区作为白色圆角卡片浮在窗口底色上（与设置窗口一致）
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 580)
        .voiceKitTextScale(textScale)
        .onAppear { tab = HistoryTab(rawValue: lastTabRaw) ?? .all }
        .onChange(of: tab) { _, newTab in
            if let newTab { lastTabRaw = newTab.rawValue }
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in
            historyItems = HistoryStore.shared.items
        }
        .onReceive(NotificationCenter.default.publisher(for: SnapshotStore.didChange)) { _ in
            snapshotCount = SnapshotStore.shared.items.count
        }
    }

    // MARK: - 侧栏

    private func count(for item: HistoryTab) -> Int {
        switch item {
        case .all: return historyItems.count
        case .favorites: return historyItems.filter(\.favorite).count
        case .snapshots: return snapshotCount
        }
    }

    private var sidebarColumn: some View {
        List(HistoryTab.allCases, selection: $tab) { t in
            HStack {
                // 字号直接打在行内容上：.sidebar 样式会忽略 List 级的 .font，
                // 否则调文字大小只撑大行高、字体不变
                Label(t.title, systemImage: t.icon)
                    .font(typography.body)
                Spacer()
                let n = count(for: t)
                if n > 0 {
                    Text("\(n)")
                        .font(typography.metadata)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .tag(t)
        }
        .listStyle(.sidebar)
        // 隐藏 List 自带背景，垫系统 .sidebar 材质（与设置窗口完全一致的侧栏观感）
        .scrollContentBackground(.hidden)
        .background(VoiceKitSidebarBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 0))
        .frame(width: 190 * textScale.multiplier)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        Group {
            switch currentTab {
            case .all:
                HistoryBrowseView(favoritesOnly: false)
            case .favorites:
                HistoryBrowseView(favoritesOnly: true)
            case .snapshots:
                SnapshotManageView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
