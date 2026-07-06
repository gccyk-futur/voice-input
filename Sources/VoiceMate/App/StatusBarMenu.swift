import SwiftUI

/// 状态栏菜单内容：入口级展示 + 退出。
/// 后续阶段（设置/历史面板）会在此扩展入口。
struct StatusBarMenu: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("VoiceMate").font(.headline)
            }
            Divider()
            Text("历史记录：\(HistoryStore.shared.items.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("历史记录…") {
                HistoryWindowController.shared.show()
            }
            Button("设置…") {
                SettingsWindowController.shared.show()
            }
            Button("退出 VoiceMate") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
    }
}
