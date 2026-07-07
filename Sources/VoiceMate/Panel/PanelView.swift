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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(coordinator.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: { coordinator.cancel() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("取消 (Esc)")
            }

            // ASR 区
            ScrollViewReader { proxy in
                ScrollView {
                    Text(coordinator.asrText.isEmpty ? "正在聆听…" : coordinator.asrText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("asrBottom")
                }
                .frame(maxHeight: .infinity)
                .onChange(of: coordinator.asrText) { _, _ in
                    withAnimation { proxy.scrollTo("asrBottom", anchor: .bottom) }
                }
            }

            // LLM 区
            if coordinator.sessionState == .ready || !coordinator.llmText.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(coordinator.llmText.isEmpty
                             ? (coordinator.sessionState == .polishing ? "润色中…" : "")
                             : coordinator.llmText)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("llmBottom")
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: coordinator.llmText) { _, _ in
                        withAnimation { proxy.scrollTo("llmBottom", anchor: .bottom) }
                    }
                }
            }

            HStack {
                Spacer()
                Button("粘贴") { coordinator.confirmPaste() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(coordinator.sessionState != .ready)
                Text("⌘↵ 粘贴").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 280, maxHeight: 500)
    }
}
