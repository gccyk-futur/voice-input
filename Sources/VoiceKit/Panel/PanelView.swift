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
            // ── 状态栏 ──
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                HStack(spacing: 4) {
                    Text(statusLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    if showHint {
                        Text("请开始讲话")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if coordinator.sessionState == .recording {
                    HStack(spacing: 1) {
                        ForEach(0..<20, id: \.self) { i in
                            AudioBar(index: i, level: coordinator.audioLevel)
                        }
                    }
                    .frame(height: 24)
                }
                Button(action: { coordinator.cancel() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("取消 (Esc)")
            }

            // ── 主文本区：有内容才显示 ──
            if !coordinator.asrText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(coordinator.asrText)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("asrBottom")
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: coordinator.asrText) { _, _ in
                        withAnimation { proxy.scrollTo("asrBottom", anchor: .bottom) }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }

            // ── AI 润色结果 ──
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

            // ── 底部栏 ──
            HStack(spacing: 0) {
                Text("Esc 退出")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                Spacer()

                HStack(spacing: 4) {
                    Text(coordinator.engineDisplayName)
                        .font(.caption2)
                    Text("·")
                        .font(.caption2)
                    Text(coordinator.llmEnabled ? "AI 润色" : "未润色")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)

                if coordinator.sessionState == .ready {
                    Button("粘贴") { coordinator.confirmPaste() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 120, maxHeight: 500)
    }

    /// 状态栏主文案（优先用 coordinator.statusText，兜底根据 sessionState 推断）
    private var statusLabel: String {
        let t = coordinator.statusText
        if !t.isEmpty, t != "按 ⌘⇧V 开始" { return t }
        switch coordinator.sessionState {
        case .recording: return "聆听中…"
        case .transcribing: return "正在识别…"
        case .polishing: return "润色中…"
        case .ready: return "识别完成"
        default: return "就绪"
        }
    }

    /// 是否显示「请开始讲话」提示（录音中且还没出字）
    private var showHint: Bool {
        coordinator.sessionState == .recording && coordinator.asrText.isEmpty
    }
}

/// 音频波形条：连续波浪效果，非独立跳动
private struct AudioBar: View {
    let index: Int
    let level: Float

    private func height(at time: TimeInterval) -> CGFloat {
        if level > 0.001 {
            // 真实电平驱动波幅
            let wave = abs(sin(Double(index) * 0.5 + time * 5))
            let amp = CGFloat(sqrt(max(0, level)) * 28)
            return max(3, amp * CGFloat(wave) + 3)
        } else {
            // 装饰动画
            let wave = abs(sin(Double(index) * 0.45 + time * 4))
            return max(3, 10 * CGFloat(wave) + 3)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let h = height(at: timeline.date.timeIntervalSinceReferenceDate)
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: 3, height: h)
        }
    }
}
