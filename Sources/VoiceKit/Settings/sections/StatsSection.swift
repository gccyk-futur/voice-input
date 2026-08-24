import SwiftUI
import Charts

// MARK: - 使用统计（自 SettingsView 拆分体系新增的分区）

extension SettingsView {

    var statsTab: some View {
        Group {
            if statsLoaded && statsSummary.isEmpty {
                ContentUnavailableView(
                    "暂无统计数据",
                    systemImage: "chart.bar",
                    description: Text("完成第一次语音输入后，这里会显示使用概况。")
                )
            } else {
                Section {
                    HStack(spacing: 4) {
                        Text("语音识别").font(typography.callout.bold())
                        Spacer()
                    }
                    statRow(overview: statsSummary.lifetime)

                    if statsSummary.llmSessions > 0 {
                        HStack(spacing: 4) {
                            Text("AI 润色").font(typography.callout.bold())
                            Spacer()
                        }
                        llmStatRow
                    }
                } footer: {
                    Text("活跃天数 = 当天有至少一次录音的自然日；软件闲置不计数。")
                }

                Section {
                    twoPieRow(
                        left: pieData(statsSummary.engines, label: { engineLabel($0) }, tint: { engineTint($0) }),
                        right: pieData(statsSummary.stopReasons, label: { stopReasonLabel($0) }, tint: { stopReasonTint($0) }),
                        leftTitle: "引擎分布",
                        rightTitle: "会话结束方式"
                    )
                }

                if !statsSummary.engineLatencies.isEmpty {
                    Section("各引擎平均出稿耗时") {
                        ForEach(statsSummary.engineLatencies, id: \.engine) { item in
                            HStack {
                                Text(engineLabel(item.engine))
                                Spacer()
                                Text(formattedLatency(item.seconds))
                                    .font(typography.body.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadStats)
    }

    // MARK: - 总计 / AI 润色

    private func statRow(overview: UsageStatsSummary.Overview) -> some View {
        HStack(spacing: 0) {
            statCell(value: grouped(overview.days), label: "活跃天数")
            statCell(value: grouped(overview.sessions), label: "录音次数")
            statCell(value: formattedDuration(overview.duration), label: "语音时长")
            statCell(value: grouped(overview.chars), label: "识别字数")
        }
        .accessibilityElement(children: .combine)
    }

    private var llmStatRow: some View {
        HStack(spacing: 0) {
            statCell(value: grouped(statsSummary.llmSessions), label: "润色次数")
            statCell(value: grouped(statsSummary.llmChars), label: "润色字数")
            statCell(value: grouped(statsSummary.llmTokens), label: "Token 用量")
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(typography.body.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(typography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 双饼图（引擎分布 + 会话结束方式）

    private struct PieSlice {
        let name: String
        let count: Int
        let color: Color
        /// 归一化权重（sum = 1），已含最小可见切片钳制。
        let weight: Double
    }

    private func pieData(_ shares: [UsageStatsSummary.CategoryShare],
                         label: @escaping (String) -> String,
                         tint: @escaping (String) -> Color) -> [PieSlice] {
        let total = shares.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        // 最小可见切片：偏斜数据下纯比例会导致极小类别在像素级消失。
        // 给每个非零类别保底 1% 角度，剩余份额按比例分摊，保证任何类别可见且大小有区分；
        // 图例仍展示真实次数，饼图只作定性占比，不展示百分比，无数量误导。
        let minFrac = 0.01
        let n = shares.count
        let extra = max(0, 1 - minFrac * Double(n))
        return shares.map { s in
            let raw = Double(s.count) / Double(total)
            return PieSlice(
                name: label(s.name),
                count: s.count,
                color: tint(s.name),
                weight: minFrac + extra * raw
            )
        }
    }

    /// 双饼图布局契约：
    /// - 两列等宽、顶部对齐（HStack alignment: .top），饼图高度固定，
    ///   因此无论左右项数多寡，两张饼图圆心始终齐平；图例在下方自然延长。
    /// - 每列自带标题（不再用外层 section 头，避免「引擎分布」与内部标题重复）。
    /// - 预估列宽：内容区 ~560pt 分给两列约 270pt，饼图 100pt 高，
    ///   图例每行 label + 次数，名称超宽用 .truncationMode 截断，不会挤压换行。
    private func twoPieRow(left: [PieSlice], right: [PieSlice], leftTitle: String, rightTitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            pieView(title: leftTitle, slices: left)
            pieView(title: rightTitle, slices: right)
        }
    }

    private func pieView(title: String, slices: [PieSlice]) -> some View {
        let total = slices.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(typography.metadata).foregroundStyle(.secondary)

            Chart {
                ForEach(slices, id: \.name) { slice in
                    SectorMark(
                        angle: .value("weight", slice.weight),
                        innerRadius: .ratio(0.62)
                    )
                    .foregroundStyle(slice.color)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 100)

            ForEach(slices, id: \.name) { slice in
                HStack(spacing: 4) {
                    Circle().fill(slice.color).frame(width: 7, height: 7)
                    Text(slice.name).font(typography.callout)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(grouped(slice.count)).font(typography.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(percentString(slice.count, of: total))
                        .font(typography.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    /// 真实占比（不随最小可见切片钳制），>=1% 取整，<1% 保留一位小数。
    private func percentString(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "" }
        let fraction = Double(count) / Double(total)
        if fraction >= 0.01 {
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        } else {
            return fraction.formatted(.percent.precision(.fractionLength(1)))
        }
    }

    // MARK: - 颜色

    private func engineTint(_ id: String) -> Color {
        switch id {
        case "system", "system-legacy": return .indigo
        case "aliyun": return .orange
        case "xunfei": return .teal
        case "deepgram": return .purple
        default: return .gray
        }
    }

    private func stopReasonTint(_ reason: String) -> Color {
        switch reason {
        case "manual": return .accentColor
        case "silence": return .green
        case "cancelled": return .gray
        case "failed": return .red
        default: return .gray
        }
    }

    // MARK: - 加载与格式化

    private func loadStats() {
        let url = UsageStatsStore.shared.fileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let text = try? String(contentsOf: url, encoding: .utf8)
            let summary = text.map {
                UsageStatsSummary.make(fromJSONL: $0, now: Date())
            } ?? UsageStatsSummary.Summary()
            Task { @MainActor in
                statsSummary = summary
                statsLoaded = true
            }
        }
    }

    /// 引擎标识 → 本地化显示名；未知引擎原样展示。
    private func engineLabel(_ id: String) -> String {
        switch id {
        case "system", "system-legacy": return VoiceKitLocalization.string("系统听写")
        case "aliyun": return VoiceKitLocalization.string("阿里云")
        case "xunfei": return VoiceKitLocalization.string("讯飞")
        case "deepgram": return "Deepgram"
        default: return id
        }
    }

    private func stopReasonLabel(_ reason: String) -> String {
        switch reason {
        case "manual": return VoiceKitLocalization.string("手动停止")
        case "silence": return VoiceKitLocalization.string("静音自动停止")
        case "cancelled": return VoiceKitLocalization.string("已取消")
        case "failed": return VoiceKitLocalization.string("失败")
        default: return reason
        }
    }

    /// 整数统一带千分位原始展示，不做 K/M/万 —— 跨语言计数法一致。
    private func grouped(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// 时长只到「小时 / 分钟」，不带秒。
    private func formattedDuration(_ seconds: Double) -> String {
        Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// 出稿耗时：<1s 用毫秒，>=1s 用秒。record 存的是秒，UI 以毫秒展示更直观。
    private func formattedLatency(_ seconds: Double) -> String {
        let ms = seconds * 1000
        if ms < 1000 {
            return VoiceKitLocalization.format("%lld 毫秒", Int(ms.rounded()))
        } else {
            return Duration.seconds(seconds)
                .formatted(.units(allowed: [.seconds], width: .narrow))
        }
    }
}
