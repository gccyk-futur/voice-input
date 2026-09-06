import SwiftUI

/// 设置侧栏「词云」页（「历史与数据」下辖子页）：当前词云（点开即算）+ 快照列表。
/// 开关/阈值/词数上限等设置项在「历史与数据」主页；本页只看结果。
/// 与「使用统计」同属本地数据洞察：所有计算都在本机，快照只存词频不含原文。
struct WordCloudSettingsSectionView: View {
    @Binding var draft: AppConfig

    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    /// 已统计的 top 词；画布尺寸变化时重布版即可，无需重扫历史
    @State private var topWords: [(word: String, count: Int)]?
    @State private var sourceCount = 0
    @State private var snapshots: [WordCloudSnapshot] = []
    @State private var previewSnapshot: WordCloudSnapshot?
    /// 画布随可用宽度自适应（窗口最小宽度下设置内容列会被压缩，定宽画布会把布局顶歪）
    @State private var canvas = CGSize(width: 520, height: 240)

    private var textScale: VoiceKitTextScale { VoiceKitTextScale.restored(from: textScaleRawValue) }
    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    private var placed: [PlacedWord]? {
        topWords.map { WordCloudLayout.place($0, in: canvas) }
    }

    var body: some View {
        Group {
            // 当前词云：点开即算（实时视图，不落盘；想留存就「存为快照」进下面列表）
            Section {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(VoiceKitLocalization.string("实时生成 · 未保存为快照"))
                        .font(typography.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("存为快照") {
                        WordCloudSnapshotter.generateSnapshot()
                    }
                    .controlSize(.small)
                    .disabled(topWords?.isEmpty ?? true)
                }
                cloudArea
                if let placed, !placed.isEmpty {
                    HStack {
                        Button("重新生成") { generate() }
                        Spacer()
                        Button("导出 HTML") {
                            WordCloudExport.html(placed: placed, canvas: canvas, sourceCount: sourceCount)
                        }
                        Button("导出 JSON") {
                            WordCloudExport.json(words: placed.map { ($0.word, $0.count) },
                                                 sourceCount: sourceCount)
                        }
                    }
                }
            } header: {
                Text("当前词云")
            } footer: {
                Text(VoiceKitLocalization.format("基于全部 %lld 条历史记录实时生成。", sourceCount))
            }

            // 快照列表
            Section {
                if snapshots.isEmpty {
                    Text(VoiceKitLocalization.string("还没有快照。开启自动快照后，积累够新增字数会自动生成；也可以立即手动生成一张。"))
                        .font(typography.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(WordCloudSnapshotPreviewSheet.formatDate(snapshot.createdAt))
                                    .font(typography.body)
                                    .monospacedDigit()
                                Text(VoiceKitLocalization.format("%lld 个词 · 基于 %lld 条历史",
                                                                 snapshot.words.count, snapshot.sourceCount))
                                    .font(typography.metadata)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("查看") { previewSnapshot = snapshot }
                                .controlSize(.small)
                            Button("删除") { WordCloudSnapshotter.delete(id: snapshot.id) }
                                .controlSize(.small)
                        }
                    }
                }
                HStack {
                    Button("立即生成一张快照") {
                        WordCloudSnapshotter.generateSnapshot()
                    }
                    .disabled(HistoryStore.shared.items.isEmpty)
                    Spacer()
                    if !snapshots.isEmpty {
                        Button("清空快照", role: .destructive) {
                            WordCloudSnapshotter.deleteAll()
                        }
                    }
                }
            } header: {
                Text("快照列表")
            } footer: {
                Text(VoiceKitLocalization.string("快照只存词频（词 + 次数），不含句子原文。自动快照的开关与触发阈值在「历史与数据」页。"))
            }
        }
        .onAppear {
            reloadSnapshots()
            generate()
        }
        .onReceive(NotificationCenter.default.publisher(for: WordCloudSnapshotter.didChange)) { _ in
            reloadSnapshots()
        }
        .sheet(item: $previewSnapshot) { snapshot in
            WordCloudSnapshotPreviewSheet(snapshot: snapshot)
        }
    }

    /// 词云画布区域：生成中也预留同尺寸容器，避免内容出现时布局左右跳动
    private var cloudArea: some View {
        ZStack {
            if let placed {
                if placed.isEmpty {
                    Text(VoiceKitLocalization.string("可用的高频词太少，还画不出词云。多积累一些历史记录后再来试试。"))
                        .font(typography.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    WordCloudCanvasView(placed: placed, canvas: canvas)
                }
            } else {
                ProgressView()
            }
        }
        // 容器宽度随 Form 列宽，高度锁定画布比例
        .frame(maxWidth: .infinity)
        .frame(height: canvas.height)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            let w = min(560, max(300, newWidth))
            guard abs(w - canvas.width) > 1 else { return }
            canvas = CGSize(width: w, height: w * 0.46)
        }
    }

    private func generate() {
        let texts = HistoryStore.shared.items
            .map { $0.llmResult ?? $0.asrResult }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        sourceCount = texts.count
        topWords = WordFrequencyAnalyzer.topWords(
            from: texts, limit: max(10, ConfigStore.shared.config.general.wordCloudWordLimit))
    }

    private func reloadSnapshots() {
        snapshots = WordCloudSnapshotter.list()
    }
}

// 给 SettingsView 提供「词云」tab 内容
extension SettingsView {
    var wordCloudTab: some View {
        WordCloudSettingsSectionView(draft: $draft)
    }
}
