import SwiftUI

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
                if coordinator.sessionState == .recording {
                    WaveBars(level: coordinator.audioLevel)
                }
                Button(action: { coordinator.cancel() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("取消 (Esc)")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(coordinator.asrText.isEmpty ? "正在聆听…" : coordinator.asrText)
                        .foregroundStyle(coordinator.asrText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("asrBottom")
                }
                .frame(maxHeight: .infinity)
                .onChange(of: coordinator.asrText) { _, _ in
                    withAnimation { proxy.scrollTo("asrBottom", anchor: .bottom) }
                }
            }

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

            HStack(spacing: 8) {
                // 左侧：快捷键提示
                Text("⌘↵ 粘贴  ·  Esc 退出")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                // 右侧：引擎 + AI 润色状态
                HStack(spacing: 4) {
                    Text(coordinator.engineDisplayName)
                        .font(.caption2)
                    Text("·")
                        .font(.caption2)
                    Text(coordinator.llmEnabled ? "AI 润色已开启" : "AI 润色已关闭")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)

                if coordinator.sessionState == .ready {
                    Button("粘贴") { coordinator.confirmPaste() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 280, maxHeight: 500)
    }
}

/// 音波条：4 根竖线高度随音频电平实时变化
private struct WaveBars: View {
    let level: Float
    private let barCount = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let h = max(4, CGFloat(level * 16 + Float(i % 2) * 4))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 2, height: h)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}
