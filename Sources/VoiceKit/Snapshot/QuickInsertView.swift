import SwiftUI
import AppKit

/// 速插浮层内容：搜索置顶（自动聚焦）+ 快照/收藏/历史 三标签。
/// 定位是「动作面」：Spotlight 式快速操作——↑↓ 选择、↵ 插入、Esc 关闭（键盘事件由
/// QuickInsertPanelController 的本地监听器转发），鼠标悬浮即选中、点击插入。
/// 只负责「插入」，不做管理（管理在历史窗口的「快照」标签）。
@MainActor
struct QuickInsertView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @AppStorage("voicekit.quickinsert.lastTab") private var lastTabRaw = QuickInsertTab.snapshot.rawValue
    @State private var tab = QuickInsertTab.snapshot
    @State private var searchText = ""
    @State private var snapshots: [SnapshotItem] = SnapshotStore.shared.items
    @State private var history: [HistoryItem] = HistoryStore.shared.items
    @State private var selectedID: String?
    /// 仅键盘导航（↑↓）置 true：选中变化时才滚动跟随；鼠标悬浮选中不滚动，
    /// 否则指针划过列表会带着列表乱滚。
    @State private var scrollToSelected = false
    @State private var toast: String?
    @FocusState private var searchFocused: Bool

    private enum QuickInsertTab: String, CaseIterable, Identifiable {
        case snapshot, favorite, recent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .snapshot: return VoiceKitLocalization.string("快照")
            case .favorite: return VoiceKitLocalization.string("收藏")
            case .recent: return VoiceKitLocalization.string("历史")
            }
        }
    }

    /// 统一行模型：三种数据源折成同一形状，选中/插入逻辑只写一遍。
    /// 快照：有标题时 标题+正文预览，无标题时只显示正文（两行）；
    /// 历史：正文为主（两行），第二行是「时间 · 引擎」元信息——避免标题与预览同文重复。
    struct Row: Identifiable {
        let id: String
        let title: String
        let preview: String?
        let meta: String?
        let insertText: String

        /// 标题可用行数：无预览/元信息时放宽到两行
        var titleLineLimit: Int { preview == nil && meta == nil ? 2 : 1 }
    }

    private var textScale: VoiceKitTextScale { VoiceKitTextScale.restored(from: textScaleRawValue) }
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }
    private var normalizedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    private func matches(_ text: String, _ extra: String?) -> Bool {
        let q = normalizedQuery
        guard !q.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(q) || (extra?.localizedCaseInsensitiveContains(q) ?? false)
    }

    private var rows: [Row] {
        switch tab {
        case .snapshot:
            return snapshots.compactMap { snap in
                guard matches(snap.text, snap.label) else { return nil }
                let trimmed = snap.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasLabel = snap.label?.isEmpty == false
                return Row(id: snap.id,
                           title: hasLabel ? snap.label! : trimmed,
                           preview: hasLabel ? trimmed : nil,
                           meta: nil,
                           insertText: snap.text)
            }
        case .favorite:
            return history.filter(\.favorite).compactMap { row(from: $0) }
        case .recent:
            return history.compactMap { row(from: $0) }
        }
    }

    private func row(from item: HistoryItem) -> Row? {
        let text = item.llmResult ?? item.asrResult
        guard matches(item.asrResult, item.llmResult) else { return nil }
        return Row(id: item.id,
                   title: text.trimmingCharacters(in: .whitespacesAndNewlines),
                   preview: nil,
                   meta: historyMeta(item),
                   insertText: text)
    }

    /// 历史行的元信息：「14:32 · 阿里云」
    private func historyMeta(_ item: HistoryItem) -> String {
        var parts: [String] = []
        if let d = ISO8601DateFormatter().date(from: item.timestamp) {
            let f = DateFormatter(); f.timeStyle = .short
            parts.append(f.string(from: d))
        }
        parts.append(item.engineDisplayName)
        return parts.joined(separator: " · ")
    }

    // MARK: - 主体

    var body: some View {
        VStack(spacing: 0) {
            // 品牌位 + 搜索 + 标签，同一工具行
            HStack(spacing: VoiceKitDesign.Spacing.md) {
                HStack(spacing: 5) {
                    Text("VoiceKit")
                        .font(typography.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                VoiceKitSearchField(placeholder: VoiceKitLocalization.string("搜索"),
                                    text: $searchText, minWidth: 120)
                    .focused($searchFocused)
                Picker("", selection: $tab) {
                    ForEach(QuickInsertTab.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            list
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Divider()
            footerBar
        }
        .frame(width: 440, height: 480)
        .voiceKitTextScale(textScale)
        .onAppear {
            tab = QuickInsertTab(rawValue: lastTabRaw) ?? .snapshot
            reload()
            searchFocused = true
            selectFirst()
        }
        .onChange(of: tab) { _, newTab in
            lastTabRaw = newTab.rawValue
            selectFirst()
        }
        .onChange(of: searchText) { _, _ in selectFirst() }
        .onReceive(NotificationCenter.default.publisher(for: SnapshotStore.didChange)) { _ in reloadSnapshots() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: QuickInsertPanelController.keyActionNotification)) { note in
            guard let action = note.object as? Int else { return }
            handleKeyAction(action)
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(typography.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// 底栏：左侧渠道+版本（品牌心智），右侧快捷键提示。
    private var footerBar: some View {
        HStack(spacing: 14) {
            Text(VoiceKitDesign.versionLine)
                .font(typography.metadata)
                .foregroundStyle(.quaternary)
            Spacer()
            hint("⇥", VoiceKitLocalization.string("切换"))
            hint("↑↓", VoiceKitLocalization.string("选择"))
            hint("↵", VoiceKitLocalization.string("插入"))
            hint("esc", VoiceKitLocalization.string("关闭"))
        }
        .font(typography.metadata)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 键帽字形 + 说明文字（SF Symbols 没有 esc/tab 的对应符号，用文字字形更准）
    private func hint(_ glyph: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(glyph).font(typography.metadata.weight(.medium))
            Text(label)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { row in
                            QuickRow(
                                row: row,
                                selected: row.id == selectedID,
                                onSelect: { selectedID = row.id },
                                onInsert: { insert(text: row.insertText) },
                                onCopy: { copy(row.insertText) }
                            )
                            .id(row.id)
                        }
                    }
                }
                .onChange(of: selectedID) { _, id in
                    guard scrollToSelected, let id else { return }
                    scrollToSelected = false
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let (title, icon): (String, String) = {
            switch tab {
            case .snapshot: return (VoiceKitLocalization.string("暂无快照"), "square.and.arrow.down.on.square")
            case .favorite: return (VoiceKitLocalization.string("暂无收藏"), "star")
            case .recent: return (VoiceKitLocalization.string("暂无记录"), "tray")
            }
        }()
        ContentUnavailableView {
            Label(title, systemImage: icon)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 键盘

    /// object 编码：-1 上移、+1 下移、2 插入选中项、3 下一个标签、4 上一个标签
    ///（由 PanelController 的本地监听转发）。
    private func handleKeyAction(_ action: Int) {
        switch action {
        case -1, 1:
            moveSelection(by: action)
        case 2:
            if let row = rows.first(where: { $0.id == selectedID }) ?? rows.first {
                insert(text: row.insertText)
            }
        case 3, 4:
            cycleTab(by: action == 3 ? 1 : -1)
        default:
            break
        }
    }

    private func cycleTab(by delta: Int) {
        let all = QuickInsertTab.allCases
        guard let idx = all.firstIndex(of: tab) else { return }
        let next = (idx + delta + all.count) % all.count
        tab = all[next]
    }

    private func moveSelection(by delta: Int) {
        let all = rows
        guard !all.isEmpty else { return }
        guard let current = selectedID, let idx = all.firstIndex(where: { $0.id == current }) else {
            scrollToSelected = true
            selectedID = delta > 0 ? all.first?.id : all.last?.id
            return
        }
        let next = max(0, min(all.count - 1, idx + delta))
        scrollToSelected = true
        selectedID = all[next].id
    }

    private func selectFirst() {
        selectedID = rows.first?.id
    }

    // MARK: - 操作

    private func insert(text: String) {
        let target = QuickInsertPanelController.shared.previousFrontmostApp
        HistoryReuseService.shared.repaste(text, to: target) { result in
            switch result {
            case .pasted:
                showToast(VoiceKitLocalization.string("已粘贴到目标应用"))
            case .copiedOnly:
                showToast(VoiceKitLocalization.string("已复制，请按 ⌘V 粘贴"))
            case .noTarget:
                showToast(VoiceKitLocalization.string("已复制到剪贴板"))
            }
            // 短暂的反馈后收起浮层（它干完活了）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                QuickInsertPanelController.shared.close()
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(VoiceKitLocalization.string("已复制"))
    }

    private func reload() {
        reloadSnapshots()
        reloadHistory()
    }

    private func reloadSnapshots() {
        snapshots = SnapshotStore.shared.items
    }

    private func reloadHistory() {
        history = HistoryStore.shared.items
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { toast = nil }
        }
    }
}

/// 速插列表行：标题 + 内容预览，悬浮即选中、点击整行插入，右侧复制按钮常显。
private struct QuickRow: View {
    let row: QuickInsertView.Row
    let selected: Bool
    let onSelect: () -> Void
    let onInsert: () -> Void
    let onCopy: () -> Void

    @Environment(\.voiceKitTextScale) private var textScale
    @State private var hovering = false

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        HStack(alignment: .center, spacing: VoiceKitDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(typography.callout.weight(.semibold))
                    .lineLimit(row.titleLineLimit)
                if let preview = row.preview {
                    Text(preview)
                        .font(typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let meta = row.meta {
                    Text(meta)
                        .font(typography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VoiceKitActionButton(systemImage: "doc.on.doc",
                                 help: VoiceKitLocalization.string("复制"), action: onCopy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.card, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            if hovering { onSelect() }
        }
        .onTapGesture(perform: onInsert)
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}
