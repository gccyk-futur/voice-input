import SwiftUI

/// 设置侧栏「历史与数据」分区。
/// 用独立 View（而非 extension 计算属性）以便持有自定义上限的临时状态。
struct HistorySettingsSectionView: View {
    @Binding var draft: AppConfig

    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var tooMany = false

    private var textScale: VoiceKitTextScale { VoiceKitTextScale.restored(from: textScaleRawValue) }
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    private static let presets = [20, 50, 100, 200, 500]

    var body: some View {
        Group {
            // 呼出快捷键：放最上面
            Section {
                HotkeyRecorder(hotkeyString: $draft.general.quickInsertHotkey)
                    .frame(height: 26)
            } header: {
                Text("呼出快捷键")
            } footer: {
                Text(VoiceKitLocalization.string("全局热键一键呼出「速插浮层」，快速把历史、收藏或快照插入当前输入位置。"))
            }

            // 保留历史：原生可编辑下拉（下拉预设 + 自定义输入）
            Section {
                HStack {
                    Text("保留历史")
                    Spacer()
                    NumericComboBox(value: $draft.general.maxHistoryCount, presets: Self.presets)
                        .frame(width: 200)
                }
            } footer: {
                if tooMany {
                    Text(VoiceKitLocalization.string("不建议超过 1 万条，会拖慢启动与使用。"))
                        .foregroundStyle(.orange)
                } else {
                    Text(VoiceKitLocalization.string("历史会自动保留最近 N 条；收藏的记录受保护，不会被自动裁剪。"))
                }
            }
            .onChange(of: draft.general.maxHistoryCount) { _, v in tooMany = v > 10_000 }

            // 当前数据
            Section {
                statRow(VoiceKitLocalization.string("历史记录"), count: currentHistoryCount)
                statRow(VoiceKitLocalization.string("收藏"), count: currentFavoriteCount)
                statRow(VoiceKitLocalization.string("快照"), count: currentSnapshotCount)
            } header: {
                Text("当前数据")
            } footer: {
                Text(VoiceKitLocalization.string("收藏与快照不受保留上限影响，可删除或清空以释放空间。"))
            }
        }
    }

    private func statRow(_ titleKey: String, count: Int) -> some View {
        HStack {
            Text(titleKey)
            Spacer()
            Text(VoiceKitLocalization.format("%lld 条", count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var currentHistoryCount: Int { HistoryStore.shared.items.count }
    private var currentFavoriteCount: Int { HistoryStore.shared.items.filter(\.favorite).count }
    private var currentSnapshotCount: Int { SnapshotStore.shared.items.count }
}

// 给 SettingsView 提供「历史与数据」tab 内容
extension SettingsView {
    var historySettingsTab: some View {
        HistorySettingsSectionView(draft: $draft)
    }
}

// MARK: - 原生可编辑下拉（NSComboBox 封装）

/// 下拉预设 + 可编辑自定义输入 —— macOS 原生 NSComboBox 的 SwiftUI 封装。
/// 用于「保留历史」这类既想给常用档、又想允许自定义的数字设置。
struct NumericComboBox: NSViewRepresentable {
    @Binding var value: Int
    let presets: [Int]

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: presets.map { String($0) })
        combo.isEditable = true
        combo.completes = false
        combo.numberOfVisibleItems = presets.count
        combo.stringValue = String(value)
        combo.delegate = context.coordinator
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        // 让 coordinator 持有最新的 binding，避免旧拷贝导致提交落空
        context.coordinator.parent = self
        if !context.coordinator.isEditing && combo.stringValue != String(value) {
            combo.stringValue = String(value)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: NumericComboBox
        var isEditing = false
        init(_ parent: NumericComboBox) { self.parent = parent }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox,
                  let s = combo.objectValueOfSelectedItem as? String,
                  let n = Int(s) else { return }
            combo.stringValue = String(n)
            parent.value = n
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let combo = obj.object as? NSComboBox else { return }
            isEditing = true
            // 实时过滤非数字：输入框只允许数字，避免中文/标点残留
            let digits = String(combo.stringValue.filter(\.isNumber))
            if digits != combo.stringValue {
                combo.stringValue = digits
            }
            // 立即提交有效值（避免点保存时因未失焦而落空）
            if let n = Int(digits) { parent.value = n }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            guard let combo = obj.object as? NSComboBox else { return }
            if let n = Int(combo.stringValue) {
                parent.value = n
            } else {
                combo.stringValue = String(parent.value)
            }
        }
    }
}
