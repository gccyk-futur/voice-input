import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 历史浏览列表（「全部」与「收藏」两个标签共用）：按天分组、搜索、展开、导出。
/// 操作按钮在展开后常显（不做悬停、不做右键）。
@MainActor
struct HistoryBrowseView: View {
    /// true 时只显示收藏（对应「收藏」标签）。
    let favoritesOnly: Bool

    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var items: [HistoryItem] = HistoryStore.shared.items
    @State private var searchText = ""
    @State private var showClearConfirm = false
    @State private var showExportSuccess = false
    @State private var showExportFailure = false
    @State private var expandAll = false
    @State private var toast: String?

    private var textScale: VoiceKitTextScale { VoiceKitTextScale.restored(from: textScaleRawValue) }
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    private var filteredItems: [HistoryItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            if favoritesOnly && !item.favorite { return false }
            guard !q.isEmpty else { return true }
            return item.asrResult.localizedCaseInsensitiveContains(q) ||
                (item.llmResult?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var groups: [HistoryDateGroup.Section] {
        HistoryDateGroup.make(from: filteredItems)
    }

    var body: some View {
        VStack(spacing: 0) {
            contentHeader
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groups, id: \.reference) { group in
                        Section {
                            ForEach(group.items) { item in
                                HistoryRowView(
                                    item: item,
                                    globalExpanded: expandAll,
                                    onCopy: { copy(item) },
                                    onRepaste: { repaste(item) },
                                    onSnapshot: { addSnapshot(item) },
                                    onFavorite: { toggleFavorite(item) },
                                    onDelete: { delete(item) },
                                    onCopyText: { copyText($0) }
                                )
                            }
                        } header: {
                            // 左侧 今天/昨天/日期标题，右侧跟随系统 locale 的短日期
                            //（行内只有时间，给分组补上日期锚点）
                            HStack {
                                Text(dayHeader(group.reference))
                                    .font(typography.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(shortDate(group.reference))
                                    .font(typography.metadata)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
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
        .voiceKitTextScale(textScale)
        .alert("清空全部历史记录？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive, action: clearAll)
            Button("取消", role: .cancel) {}
        }
        .alert("已导出", isPresented: $showExportSuccess) {
            Button("好", role: .cancel) {}
        }
        .alert("导出失败", isPresented: $showExportFailure) {
            Button("好", role: .cancel) {}
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in reload() }
    }

    // MARK: - 内容区顶部工具行

    private var contentHeader: some View {
        HStack(spacing: VoiceKitDesign.Spacing.lg) {
            VoiceKitSearchField(placeholder: VoiceKitLocalization.string("搜索历史"), text: $searchText)
            Spacer()
            Text(VoiceKitLocalization.format("%lld 条记录", filteredItems.count))
                .font(typography.callout)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
            VoiceKitActionButton(
                systemImage: expandAll ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                help: VoiceKitLocalization.string(expandAll ? "全部收起" : "全部展开")
            ) {
                withAnimation { expandAll.toggle() }
            }
            exportMenu
            Button("清空全部", role: .destructive, action: { showClearConfirm = true })
                .buttonStyle(.borderless).foregroundStyle(.red)
                .disabled(items.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(favoritesOnly ? "暂无收藏" : "暂无记录",
                  systemImage: favoritesOnly ? "star" : "tray")
        } description: {
            Text(favoritesOnly
                 ? "点击条目上的 ★ 即可收藏，方便快速找回常用内容。"
                 : "识别结果会自动保留在这里，可直接复制、收藏或重新粘贴。")
        }
    }

    // MARK: - 操作

    private func reload() { items = HistoryStore.shared.items }

    /// 行级操作的统一语义：作用于「正在展示的主文本」（润色后优先于原文）。
    /// 展开详情里的 原文 / AI 译文 各有独立复制按钮（onCopyText）。
    private func copy(_ item: HistoryItem) {
        copyText(item.llmResult ?? item.asrResult)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(VoiceKitLocalization.string("已复制"))
    }

    private func repaste(_ item: HistoryItem) {
        let target = HistoryWindowController.shared.previousFrontmostApp
        HistoryReuseService.shared.repaste(item.llmResult ?? item.asrResult, to: target) { result in
            switch result {
            case .pasted: showToast(VoiceKitLocalization.string("已粘贴到目标应用"))
            case .copiedOnly: showToast(VoiceKitLocalization.string("已复制，请按 ⌘V 粘贴"))
            case .noTarget: showToast(VoiceKitLocalization.string("未找到目标应用，已复制到剪贴板"))
            }
        }
    }

    private func addSnapshot(_ item: HistoryItem) {
        SnapshotStore.shared.add(text: item.llmResult ?? item.asrResult, label: nil)
        showToast(VoiceKitLocalization.string("已加为快照"))
    }

    private func toggleFavorite(_ item: HistoryItem) { HistoryStore.shared.toggleFavorite(item) }
    private func delete(_ item: HistoryItem) { HistoryStore.shared.remove(item) }
    private func clearAll() { HistoryStore.shared.clear() }

    // MARK: - 导出

    private var exportMenu: some View {
        VoiceKitActionMenu(systemImage: "square.and.arrow.up",
                           help: VoiceKitLocalization.string("导出…")) {
            Button("导出 Markdown") { export(format: .markdown) }
            Button("导出 JSON") { export(format: .json) }
        }
        .disabled(filteredItems.isEmpty)
    }

    private enum ExportFormat {
        case markdown, json
        var filename: String {
            let base = VoiceKitLocalization.string("VoiceKit 历史")
            return self == .markdown ? base + ".md" : base + ".json"
        }
        var allowedType: UTType { self == .markdown ? .plainText : .json }
    }

    private func export(format: ExportFormat) {
        guard let url = savePanel(format: format) else { return }
        let content: String
        switch format {
        case .markdown: content = markdownExport()
        case .json: content = jsonExport()
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            showExportSuccess = true
        } catch {
            showExportFailure = true
        }
    }

    private func savePanel(format: ExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format.filename
        panel.allowedContentTypes = [format.allowedType]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func markdownExport() -> String {
        let ts = DateFormatter(); ts.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# " + VoiceKitLocalization.string("VoiceKit 历史") + "\n\n"
        for group in groups {
            out += "## \(dayHeader(group.reference))\n\n"
            for item in group.items {
                let time = iso(item.timestamp).map { ts.string(from: $0) } ?? item.timestamp
                let engine = item.engineDisplayName
                let body = item.llmResult ?? item.asrResult
                out += "- **\(time)** (\(engine))\n\n  \(body)\n\n"
                if let llm = item.llmResult, llm != item.asrResult {
                    out += "  - " + VoiceKitLocalization.string("润色后") + ": \(llm)\n\n"
                }
            }
        }
        return out
    }

    private func jsonExport() -> String {
        let payload = filteredItems.map { item -> [String: Any] in
            ["time": item.timestamp, "engine": item.engine,
             "asr": item.asrResult, "llm": item.llmResult ?? NSNull(),
             "favorite": item.favorite]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - 展示辅助

    private func dayHeader(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return VoiceKitLocalization.string("今天") }
        if calendar.isDateInYesterday(day) { return VoiceKitLocalization.string("昨天") }
        return DateFormatter.dateMedium.string(from: day)
    }

    /// 短日期（随系统 locale：zh 2026/8/25、en 8/25/26、de 25.08.26 …）
    private func shortDate(_ day: Date) -> String {
        DateFormatter.localizedString(from: day, dateStyle: .short, timeStyle: .none)
    }

    private func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toast = nil }
        }
    }
}

extension DateFormatter {
    static let dateMedium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
}
