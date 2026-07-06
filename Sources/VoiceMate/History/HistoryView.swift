import SwiftUI

/// 历史记录窗口内容：浏览、复制、收藏、删除、清空。
/// 实时跟随 HistoryStore（store 变更会发 VoiceMateHistoryDidChange 通知）。
@MainActor
struct HistoryView: View {
    @State private var items: [HistoryItem] = HistoryStore.shared.items
    @State private var selectedID: HistoryItem.ID?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史记录").font(.headline)
                Text("(\(items.count))").foregroundStyle(.secondary)
                Spacer()
                Button("清空全部", role: .destructive, action: { showClearConfirm = true })
                    .disabled(items.isEmpty)
            }
            .padding(10)

            Divider()

            if items.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("暂无记录").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(selection: $selectedID) {
                    ForEach(items) { item in
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
        .frame(width: 560, height: 520)
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

                Text(timeLabel).font(.caption).foregroundStyle(.secondary)

                Text(item.engine).font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if item.llmEngine != nil {
                    Text("已润色").font(.caption2).foregroundStyle(.tint)
                }

                Spacer()

                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("复制")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .help("删除")
                    .foregroundStyle(.red)
            }

            Text(item.llmResult ?? item.asrResult)
                .lineLimit(3)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
