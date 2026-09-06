import SwiftUI

/// 历史单条：元信息（时间 / 引擎 / 已润色 / 已纠正 / 收藏）在头部，正文居中，
/// 底部左侧「展开」开关、右侧整排常显操作按钮。不做悬停才出现、不做右键。
/// 操作语义：复制 / 重新粘贴 / 加为快照 一律作用于「正在展示的主文本」（润色后优先）；
/// 展开详情里 原文 / AI 译文 另有各自的复制按钮（onCopyText）。
/// 有语音留档的条目：操作行出现 播放/停止、时长与「重新识别」（用当时的引擎补识别）。
struct HistoryRowView: View {
    let item: HistoryItem
    /// 工具行「全部展开」开关：true 时所有行强制展开。
    let globalExpanded: Bool
    let onCopy: () -> Void
    let onRepaste: () -> Void
    let onSnapshot: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void
    /// 展开详情中复制指定段落（原文 / AI 译文）。
    let onCopyText: (String) -> Void
    /// 语音留档：播放/停止切换、是否正在播放本条、触发重新识别、本条是否识别中。
    let onTogglePlayAudio: () -> Void
    let isPlayingAudio: Bool
    let onRetranscribe: () -> Void
    let isRetranscribing: Bool

    @Environment(\.voiceKitTextScale) private var textScale
    @State private var expanded = false

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }
    private var hasBoth: Bool { item.llmResult != nil && item.llmResult != item.asrResult }
    private var mainText: String { item.llmResult ?? item.asrResult }
    private var hasText: Bool { !mainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isExpanded: Bool { expanded || globalExpanded }

    /// 短文本展开后没有任何新内容，此时不显示展开开关。
    private var canExpand: Bool {
        hasBoth || item.asrRaw != nil || mainText.count > 100 || mainText.contains("\n")
    }

    private var timeLabel: String {
        if let d = ISO8601DateFormatter().date(from: item.timestamp) {
            let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d)
        }
        return item.timestamp
    }

    private var durationLabel: String? {
        guard let d = item.audioDuration, d > 0 else { return nil }
        let total = Int(d.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.sm) {
            header
            if isExpanded {
                detail
            } else if hasText {
                Text(mainText)
                    .lineLimit(2)
                    .font(typography.body)
                    .textSelection(.enabled)
            } else {
                Text("（未识别到内容，可回放语音排查或重新识别）")
                    .font(typography.body)
                    .foregroundStyle(.secondary)
            }
            actionRow
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - 头部元信息

    private var header: some View {
        HStack(spacing: VoiceKitDesign.Spacing.sm) {
            Text(timeLabel)
                .font(typography.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(item.engineDisplayName)
                .font(typography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
            if item.llmEngine != nil {
                Text("已润色")
                    .font(typography.metadata)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            if item.asrRaw != nil {
                Text("已纠正")
                    .font(typography.metadata)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .voiceKitToolTip(VoiceKitLocalization.string("识别文本经本地词汇纠正，展开可查看原始识别"))
            }
            Spacer()
            Button(action: onFavorite) {
                Image(systemName: item.favorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(item.favorite ? .yellow : Color.secondary.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .voiceKitToolTip(item.favorite
                  ? VoiceKitLocalization.string("取消收藏")
                  : VoiceKitLocalization.string("收藏"))
            .accessibilityLabel(item.favorite
                                ? VoiceKitLocalization.string("取消收藏")
                                : VoiceKitLocalization.string("收藏"))
        }
    }

    // MARK: - 原文 / AI 译文

    private func detailSection(_ title: String, text: String, tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.xs) {
            HStack {
                Text(title)
                    .font(typography.metadata.weight(.semibold))
                    .foregroundStyle(tinted ? Color.accentColor : .secondary)
                Spacer()
                VoiceKitActionButton(
                    systemImage: "doc.on.doc",
                    help: VoiceKitLocalization.string("复制")
                ) {
                    onCopyText(text)
                }
            }
            Text(text)
                .font(typography.body)
                .textSelection(.enabled)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.sm) {
            if let raw = item.asrRaw {
                detailSection("原始识别（纠正前）", text: raw, tinted: false)
                Divider()
            }
            if hasBoth {
                detailSection("原文", text: item.asrResult, tinted: false)
                Divider()
                detailSection("AI 译文", text: item.llmResult ?? "", tinted: true)
            } else if hasText {
                Text(mainText)
                    .font(typography.body)
                    .textSelection(.enabled)
            } else {
                Text("（未识别到内容，可回放语音排查或重新识别）")
                    .font(typography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.card, style: .continuous)
        )
        .transition(.opacity)
    }

    // MARK: - 操作行（整排常显）

    private var actionRow: some View {
        HStack(spacing: VoiceKitDesign.Spacing.xs) {
            if canExpand {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(expandLabel)
                    }
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .voiceKitToolTip(VoiceKitLocalization.string(isExpanded ? "收起" : "展开"))
            }

            // 语音留档：播放/停止 + 时长 + 重新识别
            if item.audioFile != nil {
                VoiceKitActionButton(
                    systemImage: isPlayingAudio ? "stop.fill" : "play.fill",
                    help: VoiceKitLocalization.string(isPlayingAudio ? "停止播放" : "播放语音"),
                    action: onTogglePlayAudio
                )
                if let durationLabel {
                    Text(durationLabel)
                        .font(typography.metadata)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if isRetranscribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    VoiceKitActionButton(
                        systemImage: "waveform.and.magnifyingglass",
                        help: VoiceKitLocalization.string("重新识别（用当时的引擎再试一次，不覆盖原文字）"),
                        action: onRetranscribe
                    )
                }
            }

            Spacer()

            VoiceKitActionButton(systemImage: "doc.on.doc",
                                 help: VoiceKitLocalization.string("复制"), action: onCopy)
                .disabled(!hasText)
            VoiceKitActionButton(systemImage: "arrow.uturn.left",
                                 help: VoiceKitLocalization.string("重新粘贴"), action: onRepaste)
                .disabled(!hasText)
            VoiceKitActionButton(systemImage: "square.and.arrow.down.on.square",
                                 help: VoiceKitLocalization.string("加为快照"), action: onSnapshot)
                .disabled(!hasText)
            VoiceKitActionButton(systemImage: "trash",
                                 help: VoiceKitLocalization.string("删除"), destructive: true, action: onDelete)
        }
    }

    private var expandLabel: String {
        if hasBoth {
            return isExpanded ? "收起" : "原文与 AI 译文"
        }
        return isExpanded ? "收起" : "展开"
    }
}
