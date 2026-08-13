import SwiftUI

struct PanelView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @Environment(AppCoordinator.self) private var coordinator

    private var textScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: textScale)
    }

    private var statusColor: Color {
        switch coordinator.sessionState {
        case .recording: return VoiceKitSemanticColor.failure
        case .preparing: return VoiceKitSemanticColor.warning
        case .failed: return VoiceKitSemanticColor.failure
        case .transcribing, .polishing: return VoiceKitSemanticColor.warning
        case .ready: return VoiceKitSemanticColor.success
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── 状态栏 ──
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                // 面板只保留两个字号层级：内容（状态行 + 转录正文，同为 body）
                // 与边角信息（底部栏 metadata）。原先状态行用 callout（12pt），
                // 与正文 13pt 只差一档——差别不够明显时不像层级，像失误，
                // 也让人觉得「说着说着字变小了」。层级改由颜色承担。
                // fixedSize 防止录音时被时长与音波挤压。
                HStack(spacing: 4) {
                    Text(statusLabel)
                        .font(typography.body).foregroundStyle(.secondary)
                        .fixedSize()
                    if showHint {
                        Text(VoiceKitLocalization.string("请开始讲话"))
                            .font(typography.body).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Spacer()
                // 时长贴着音波放在右侧，而不是跟在状态文案后面：
                // 状态文案长度会随阶段变化（准备中…/聆听中…/正在识别…），
                // 跟在它后面时长会左右跳动；靠右则位置恒定。
                if coordinator.sessionState == .recording {
                    if let started = coordinator.recordingStartedAt {
                        RecordingDuration(startedAt: started, limit: coordinator.sessionMaxDuration)
                            .font(typography.body)
                            .fixedSize()
                    }
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
                .accessibilityLabel(VoiceKitLocalization.string("取消听写"))
                .help(VoiceKitLocalization.string("取消 (Esc)"))
            }

            if let notice = coordinator.recoveryNotice {
                RecoveryCard(notice: notice) { action in
                    coordinator.performRecoveryAction(action)
                }
            } else {
                // ── 主文本区：有内容才显示 ──
                if !coordinator.asrText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(coordinator.asrText)
                                .font(typography.body)
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
                                 ? (coordinator.sessionState == .polishing ? VoiceKitLocalization.string("润色中…") : "")
                                 : coordinator.llmText)
                                .font(typography.body)
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
            }

            // ── 底部栏 ──
            HStack(spacing: 0) {
                Text(VoiceKitLocalization.string("Esc 退出"))
                    .font(typography.metadata)
                    .foregroundStyle(.secondary)
                
                Spacer()

                HStack(spacing: 4) {
                    Text(coordinator.engineDisplayName)
                        .font(typography.metadata)
                    Text("·")
                        .font(typography.metadata)
                    Text(coordinator.llmEnabled
                         ? VoiceKitLocalization.string("AI 润色")
                         : VoiceKitLocalization.string("未润色"))
                        .font(typography.metadata)
                }
                .foregroundStyle(.secondary)

                if coordinator.sessionState == .ready {
                    Button("粘贴") { coordinator.confirmPaste() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 120, maxHeight: 500)
        .voiceKitTextScale(textScale)
    }

    /// 状态栏主文案（优先用 coordinator.statusText，兜底根据 sessionState 推断）
    private var statusLabel: String {
        if coordinator.recoveryNotice != nil { return VoiceKitLocalization.string("需要处理") }
        let t = coordinator.statusText
        if !t.isEmpty, t != VoiceKitLocalization.string("按 ⌘⇧V 开始") { return t }
        switch coordinator.sessionState {
        case .preparing: return VoiceKitLocalization.string("准备中…")
        case .recording: return VoiceKitLocalization.string("聆听中…")
        case .transcribing: return VoiceKitLocalization.string("正在识别…")
        case .polishing: return VoiceKitLocalization.string("润色中…")
        case .ready: return VoiceKitLocalization.string("识别完成")
        default: return VoiceKitLocalization.string("就绪")
        }
    }

    /// 是否显示「请开始讲话」提示（录音中且还没出字）
    private var showHint: Bool {
        coordinator.sessionState == .recording && coordinator.asrText.isEmpty
    }
}

private struct RecoveryCard: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    let notice: RecordingRecoveryNotice
    let onAction: (RecordingRecoveryAction) -> Void

    /// 此前这里硬编码 .headline / .body，完全绕开了字号设置——
    /// 用户把界面字号调大后，唯独出错提示卡不跟着变。改用统一的排版令牌。
    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: VoiceKitTextScale.restored(from: textScaleRawValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(notice.title, systemImage: "exclamationmark.triangle.fill")
                .font(typography.sectionTitle)
                .foregroundStyle(.red)

            Text(notice.message)
                .font(typography.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(notice.primaryAction.title) {
                    onAction(notice.primaryAction)
                }
                .buttonStyle(.borderedProminent)

                if let secondaryAction = notice.secondaryAction {
                    Button(secondaryAction.title) {
                        onAction(secondaryAction)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.22), lineWidth: 1)
        )
        .padding(.vertical, 12)
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
                // 录音红：与状态圆点同色，浅色/深色模式下都清晰可见
                // （原先的白色 20% 透明度在浅色模式的 popover 材质上几乎不可见）
                .fill(VoiceKitSemanticColor.failure.opacity(0.75))
                .frame(width: 3, height: h)
        }
    }
}

/// 录制时长。对有服务端会话上限的引擎（讯飞 60s）额外显示上限并在临近时转为橙色，
/// 让用户在被强制断开前主动收尾，而不是说到一半被掐断。
private struct RecordingDuration: View {
    let startedAt: Date
    let limit: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            Text(text(elapsed))
                .monospacedDigit()
                .foregroundStyle(tint(elapsed))
                .accessibilityLabel(Text(VoiceKitLocalization.string("已录制") + " " + mmss(elapsed)))
        }
    }

    private func text(_ elapsed: TimeInterval) -> String {
        guard let limit else { return mmss(elapsed) }
        return "\(mmss(elapsed)) / \(mmss(limit))"
    }

    private func mmss(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    /// 距上限不足 10 秒时转橙，提示该收尾了。
    private func tint(_ elapsed: TimeInterval) -> Color {
        guard let limit else { return .secondary }
        return elapsed >= limit - 10 ? .orange : .secondary
    }
}
