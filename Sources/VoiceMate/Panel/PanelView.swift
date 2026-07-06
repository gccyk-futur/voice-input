import SwiftUI

/// 悬浮窗内容：上半区 ASR（灰，实时），下半区 LLM（黑，逐字）。
/// 语义化颜色自动适配深色模式与无障碍对比度（HIG）。
struct PanelView: View {
    @Environment(AppCoordinator.self) private var coordinator

    private var statusColor: Color {
        switch coordinator.sessionState {
        case .recording: return .red
        case .transcribing, .polishing: return .orange
        case .ready: return .green
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { coordinator.cancel() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("取消 (Esc)")
            }

            // ASR 区（灰）
            ScrollView {
                Text(coordinator.asrText.isEmpty ? "正在聆听…" : coordinator.asrText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)

            // LLM 区（黑）
            if coordinator.sessionState == .ready || !coordinator.llmText.isEmpty {
                Divider()
                ScrollView {
                    let display = coordinator.llmText.isEmpty
                        ? (coordinator.sessionState == .polishing ? "润色中…" : "")
                        : coordinator.llmText
                    Text(display)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 80)
            }

            HStack {
                Spacer()
                Button("粘贴", action: { coordinator.confirmPaste() })
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(coordinator.sessionState != .ready)
                Text("⌘↵ 粘贴")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 480)
    }
}
