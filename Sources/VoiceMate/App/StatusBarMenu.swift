import SwiftUI

/// 状态栏菜单：状态区 + 操作区。
/// 每次打开菜单时重新读取 AppCoordinator 状态，保证实时。
struct StatusBarMenu: View {
    // 直接读 shared，因为 MenuBarExtra 不继承 @Environment
    private var coordinator: AppCoordinator { AppCoordinator.shared }
    private var engineId: String { ConfigStore.shared.config.asr.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("VoiceMate").font(.headline)
            }

            Divider()

            // ── 状态区 ──
            statusRow(label: "引擎", value: coordinator.engineDisplayName)
            if engineId == "aliyun" {
                HStack(spacing: 4) {
                    Circle()
                        .fill(coordinator.wsConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(coordinator.wsConnected ? "WebSocket 已连接" : "WebSocket 未连接")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }
            HStack {
                Text("AI 润色").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { ConfigStore.shared.config.llm.enabled },
                    set: { v in
                        var cfg = ConfigStore.shared.config
                        cfg.llm.enabled = v
                        ConfigStore.shared.update(cfg)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            Divider()

            // ── 操作区 ──
            Button("历史记录…") {
                HistoryWindowController.shared.show()
            }
            Button("设置…") {
                SettingsWindowController.shared.show()
            }

            Divider()

            Button("退出 VoiceMate") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(minWidth: 220)
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }
}
