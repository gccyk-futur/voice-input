import SwiftUI

/// 快照管理（历史窗口「快照」标签）：列表 + 搜索 + 添加 / 编辑 / 删除。
/// 这里负责「管理」，速插浮层负责「插入」，两者共享 SnapshotStore。
@MainActor
struct SnapshotManageView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var items: [SnapshotItem] = SnapshotStore.shared.items
    @State private var searchText = ""
    @State private var editing: SnapshotItem?
    @State private var showNewSheet = false
    @State private var pendingDelete: SnapshotItem?

    private var textScale: VoiceKitTextScale { VoiceKitTextScale.restored(from: textScaleRawValue) }
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    private var filtered: [SnapshotItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.label?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            contentHeader
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("暂无快照", systemImage: "square.and.arrow.down.on.square")
                } description: {
                    Text("在历史条目上点「加为快照」，或在下方手动添加一段文字。")
                }
                // 同 HistoryBrowseView：空态必须显式撑满，否则内容区垂直居中漂移
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { item in
                        SnapshotManageRow(
                            item: item,
                            onEdit: { editing = item },
                            onDelete: { pendingDelete = item },
                            onCopy: { copy(item.text) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .voiceKitTextScale(textScale)
        .sheet(item: $editing) { item in
            SnapshotEditorSheet(item: item, isNew: false)
        }
        .sheet(isPresented: $showNewSheet) {
            SnapshotEditorSheet(item: SnapshotItem(text: "", label: nil), isNew: true)
        }
        .confirmationDialog("删除这条快照？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let p = pendingDelete { SnapshotStore.shared.delete(p) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: SnapshotStore.didChange)) { _ in reload() }
    }

    private var contentHeader: some View {
        HStack(spacing: VoiceKitDesign.Spacing.lg) {
            VoiceKitSearchField(placeholder: VoiceKitLocalization.string("搜索快照"), text: $searchText)
            Spacer()
            Text(VoiceKitLocalization.format("%lld 条快照", filtered.count))
                .font(typography.callout)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
            Button {
                showNewSheet = true
            } label: {
                Label("新建快照", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func reload() { items = SnapshotStore.shared.items }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 快照管理列表行：标题 + 内容预览，操作按钮常显。
private struct SnapshotManageRow: View {
    let item: SnapshotItem
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void

    @Environment(\.voiceKitTextScale) private var textScale
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    private var title: String {
        if let label = item.label, !label.isEmpty { return label }
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(18))
        return trimmed.count > 18 ? prefix + "…" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.xs) {
            HStack(spacing: VoiceKitDesign.Spacing.sm) {
                Text(title)
                    .font(typography.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                VoiceKitActionButton(systemImage: "doc.on.doc",
                                     help: VoiceKitLocalization.string("复制"), action: onCopy)
                VoiceKitActionButton(systemImage: "pencil",
                                     help: VoiceKitLocalization.string("编辑"), action: onEdit)
                VoiceKitActionButton(systemImage: "trash",
                                     help: VoiceKitLocalization.string("删除"), destructive: true, action: onDelete)
            }
            Text(item.text)
                .font(typography.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.vertical, 6)
    }
}

/// 快照编辑/新建 sheet：文本内容 + 可选标题。
private struct SnapshotEditorSheet: View {
    let item: SnapshotItem
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var label: String

    init(item: SnapshotItem, isNew: Bool) {
        self.item = item
        self.isNew = isNew
        _text = State(initialValue: item.text)
        _label = State(initialValue: item.label ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.lg) {
            Text(isNew ? "新建快照" : "编辑快照")
                .font(.headline)
            TextField("标题（可选）", text: $label)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 140)
                .padding(4)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button(isNew ? "添加" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            SnapshotStore.shared.add(text: t, label: label.isEmpty ? nil : label)
        } else {
            SnapshotStore.shared.update(id: item.id, text: t, label: label.isEmpty ? nil : label)
        }
        dismiss()
    }
}
