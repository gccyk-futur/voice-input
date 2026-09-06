import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 词云画布：预览（app 内）与 HTML 导出共用同一份 PlacedWord 布局，所见即所得。
/// 历史窗口 Sheet、设置「词云」页、快照预览 Sheet 三处复用。
struct WordCloudCanvasView: View {
    let placed: [PlacedWord]
    let canvas: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            ForEach(Array(placed.enumerated()), id: \.offset) { rank, p in
                Text(p.word)
                    .font(.system(size: p.fontSize, weight: .semibold))
                    .foregroundStyle(Color(wordCloudHex: WordCloudLayout.color(forRank: rank)))
                    .offset(x: p.frame.minX, y: p.frame.minY)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

/// 词云导出：HTML（自包含网页）与 JSON（词 + 频次结构化数据）共用的落盘逻辑。
enum WordCloudExport {

    static func html(placed: [PlacedWord], canvas: CGSize, sourceCount: Int) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = VoiceKitLocalization.string("VoiceKit 词云") + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = WordCloudHTMLExporter.export(placed: placed, canvas: canvas, sourceCount: sourceCount)
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    static func json(words: [(word: String, count: Int)], sourceCount: Int, createdAt: String? = nil) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = VoiceKitLocalization.string("VoiceKit 词云") + ".json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var payload: [String: Any] = [
            "sourceCount": sourceCount,
            "words": words.map { ["word": $0.word, "count": $0.count] }
        ]
        if let createdAt { payload["createdAt"] = createdAt }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}

/// 快照预览 Sheet：从已存词频直接布版（不重新扫历史），可导出 HTML/JSON。
struct WordCloudSnapshotPreviewSheet: View {
    let snapshot: WordCloudSnapshot

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }
    private let canvas = CGSize(width: 660, height: 380)

    private var placed: [PlacedWord] {
        WordCloudLayout.place(snapshot.words.map { ($0.word, $0.count) }, in: canvas)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(VoiceKitLocalization.string("词云快照")).font(typography.sectionTitle)
                Text(Self.formatDate(snapshot.createdAt))
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(VoiceKitLocalization.format("基于 %lld 条历史", snapshot.sourceCount))
                    .font(typography.metadata)
                    .foregroundStyle(.tertiary)
            }

            if snapshot.words.isEmpty {
                ContentUnavailableView {
                    Label("暂无可用词汇", systemImage: "cloud")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WordCloudCanvasView(placed: placed, canvas: canvas)
            }

            HStack {
                Button("导出 HTML") {
                    WordCloudExport.html(placed: placed, canvas: canvas, sourceCount: snapshot.sourceCount)
                }
                .disabled(snapshot.words.isEmpty)
                Button("导出 JSON") {
                    WordCloudExport.json(
                        words: snapshot.words.map { ($0.word, $0.count) },
                        sourceCount: snapshot.sourceCount, createdAt: snapshot.createdAt)
                }
                .disabled(snapshot.words.isEmpty)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 540)
    }

    static func formatDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// 历史词云 Sheet（历史窗口工具栏入口）：生成当前历史的词云，可导出 HTML/JSON。
/// 预览与导出共用 WordCloudLayout 的同一份布局结果，所见即所得。
struct WordCloudSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale

    @State private var placed: [PlacedWord]?
    @State private var sourceCount = 0

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }
    private let canvas = CGSize(width: 660, height: 380)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("历史词云").font(typography.sectionTitle)

            if let placed {
                if placed.isEmpty {
                    emptyHint
                } else {
                    WordCloudCanvasView(placed: placed, canvas: canvas)
                }
            } else {
                idleHint
            }

            HStack {
                if placed != nil {
                    Button("重新生成") { generate() }
                    Button("导出 HTML") {
                        guard let placed else { return }
                        WordCloudExport.html(placed: placed, canvas: canvas, sourceCount: sourceCount)
                    }
                    Button("导出 JSON") {
                        guard let placed else { return }
                        WordCloudExport.json(
                            words: placed.map { ($0.word, $0.count) },
                            sourceCount: sourceCount)
                    }
                }
                Spacer()
                Button(placed == nil ? "关闭" : "完成") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 720, height: 540)
    }

    // MARK: - 状态视图

    private var idleHint: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cloud")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(VoiceKitLocalization.string("从历史记录的文本中提取高频词，生成一张词云图。"))
                .font(typography.body)
                .foregroundStyle(.secondary)
            Text(VoiceKitLocalization.string("只在本机分析，不会上传任何内容。"))
                .font(typography.callout)
                .foregroundStyle(.tertiary)
            Button("生成词云") { generate() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(VoiceKitLocalization.string("可用的高频词太少，还画不出词云。"))
                .font(typography.body)
                .foregroundStyle(.secondary)
            Text(VoiceKitLocalization.string("多积累一些历史记录后再来试试。"))
                .font(typography.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 生成

    private func generate() {
        let texts = HistoryStore.shared.items
            .map { $0.llmResult ?? $0.asrResult }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        sourceCount = texts.count
        let top = WordFrequencyAnalyzer.topWords(
            from: texts, limit: max(10, ConfigStore.shared.config.general.wordCloudWordLimit))
        placed = WordCloudLayout.place(top, in: canvas)
    }
}

extension Color {
    init(wordCloudHex: String) {
        var value: UInt64 = 0
        Scanner(string: wordCloudHex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
