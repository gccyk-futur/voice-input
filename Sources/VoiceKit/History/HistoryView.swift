import SwiftUI

/// 历史记录窗口内容：浏览、复制、收藏、删除、清空。
/// 实时跟随 HistoryStore（store 变更会发 VoiceMateHistoryDidChange 通知）。
@MainActor
struct HistoryView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var items: [HistoryItem] = HistoryStore.shared.items
    @State private var selectedID: HistoryItem.ID?
    @State private var searchText = ""
    @State private var showClearConfirm = false

    private var textScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: textScale)
    }

    /// 搜索过滤：匹配识别原文或润色结果，大小写不敏感
    private var filteredItems: [HistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.asrResult.localizedCaseInsensitiveContains(query) ||
            ($0.llmResult?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if filteredItems.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("暂无记录",
                                           systemImage: "tray",
                                           description: Text("识别结果会自动保留在这里，可直接复制或收藏"))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredItems) { item in
                        HistoryRow(
                            item: item,
                            onCopy: { copy(item) },
                            onFavorite: { toggleFavorite(item) },
                            onDelete: { delete(item) }
                        )
                        .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索历史")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("\(items.count) 条记录")
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("清空全部", role: .destructive, action: { showClearConfirm = true })
                    .disabled(items.isEmpty)
            }
        }
        .voiceKitTextScale(textScale)
        .alert("清空全部历史记录？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive, action: clearAll)
            Button("取消", role: .cancel) {}
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in reload() }
    }

    private func reload() {
        items = HistoryStore.shared.items
    }

    private func copy(_ item: HistoryItem) {
        let text = item.llmResult ?? item.asrResult
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func toggleFavorite(_ item: HistoryItem) {
        HistoryStore.shared.toggleFavorite(item)
    }

    private func delete(_ item: HistoryItem) {
        HistoryStore.shared.remove(item)
        if selectedID == item.id { selectedID = nil }
    }

    private func clearAll() {
        HistoryStore.shared.clear()
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let onCopy: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void

    @Environment(\.voiceKitTextScale) private var textScale

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: textScale)
    }

    private var timeLabel: String {
        if let d = ISO8601DateFormatter().date(from: item.timestamp) {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return f.string(from: d)
        }
        return item.timestamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: onFavorite) {
                    Image(systemName: item.favorite ? "star.fill" : "star")
                        .foregroundStyle(item.favorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.favorite ? "取消收藏" : "收藏")

                Text(timeLabel).font(typography.callout).foregroundStyle(.secondary)

                Text(item.engine).font(typography.metadata)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if item.llmEngine != nil {
                    Text("已润色").font(typography.metadata).foregroundStyle(.tint)
                }

                Spacer()

                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制")
                    .help("复制")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除")
                    .help("删除")
                    .foregroundStyle(.red)
            }

            Text(item.llmResult ?? item.asrResult)
                .lineLimit(3)
                .font(typography.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
