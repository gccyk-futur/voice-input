import Foundation
import NaturalLanguage

/// 历史词云的纯逻辑层：词频统计 + 确定性布局。
/// UI 预览（WordCloudView）与 HTML 导出（WordCloudHTMLExporter）共用同一份 PlacedWord，
/// 保证「所见即所得」——用户在 app 里看到的词云和导出文件里的一模一样。

// MARK: - 词频统计

enum WordFrequencyAnalyzer {

    /// 从一组文本中统计 top 词。
    /// - 中文按词切分（NLTokenizer），单字词丢弃（噪音大、信息量少）；
    /// - 拉丁词小写归并，少于 2 个字母丢弃；
    /// - 纯数字 / 纯标点 / 内置停用词（中英口语虚词）丢弃。
    static func topWords(from texts: [String], limit: Int = 60) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for text in texts {
            for token in tokens(in: text) {
                counts[token, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= 2 || $0.key.count >= 3 }  // 只出现 1 次的长词保留，短词需复现
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    /// 单条文本 → 归一化后的有效词序列。
    static func tokens(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            if let normalized = normalize(raw) { out.append(normalized) }
            return true
        }
        return out
    }

    private static func normalize(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // 纯数字 / 纯标点不要
        if t.allSatisfy({ $0.isNumber }) { return nil }
        if t.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return nil }
        if containsCJK(t) {
            guard t.count >= 2 else { return nil }
            return stopwords.contains(t) ? nil : t
        }
        let lowered = t.lowercased()
        guard lowered.count >= 2 else { return nil }
        guard lowered.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return stopwords.contains(lowered) ? nil : lowered
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 中英口语虚词。词云的价值在「主题词」，虚词只会淹没版面。
    /// 用块字符串承载：这是分词数据而非 UI 文案，不应进入 Localizable.strings
    /// （LocalizationMissingKeyTests 只扫描单行引号字面量）。
    static let stopwords: Set<String> = Set(
        """
        就是 然后 这个 那个 什么 怎么 我们 你们 他们 可以
        没有 一个 现在 还是 因为 所以 但是 如果 已经 应该
        可能 觉得 知道 这样 那样 时候 东西 问题 地方 一下
        不是 有点 比较 真的 其实 大概 或者 而且 的话 是不是
        这么 那么 为什么 怎么样 自己 今天 明天 昨天 开始
        the a an and or but if then so to of in
        on at for with is are was were be been it
        this that these those i you he she we they
        my your his her our their me him us them
        do does did have has had not no yes just
        like okay ok yeah well um uh oh ah gonna
        will would can could should there here what how
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    )
}

// MARK: - 确定性布局

/// 一个已定位的词：frame 为画布左上角坐标系。
struct PlacedWord: Equatable {
    let word: String
    let count: Int
    let fontSize: Double
    let frame: CGRect
}

enum WordCloudLayout {

    static let minFont: Double = 13
    static let maxFont: Double = 46

    /// 阿基米德螺线从画布中心向外摆放；同一输入永远得到同一布局。
    /// 词按计数降序处理：大词占中心，小词填缝隙。
    static func place(_ words: [(word: String, count: Int)], in canvas: CGSize) -> [PlacedWord] {
        guard let maxCount = words.map(\.count).max(), maxCount > 0 else { return [] }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        var placed: [PlacedWord] = []
        var frames: [CGRect] = []

        for entry in words {
            let scale = sqrt(Double(entry.count) / Double(maxCount))
            let fontSize = (minFont + (maxFont - minFont) * scale).rounded()
            let textSize = estimateSize(of: entry.word, fontSize: fontSize)
            guard let frame = findFreeFrame(
                textSize: textSize, center: center, canvas: canvas, occupied: frames
            ) else { continue }  // 摆不下的小词宁可丢弃，也不重叠
            placed.append(PlacedWord(word: entry.word, count: entry.count,
                                     fontSize: fontSize, frame: frame))
            frames.append(frame.insetBy(dx: -3, dy: -2))
        }
        return placed
    }

    /// 估算渲染尺寸：CJK 按全宽，拉丁按 0.56 em，词间距少量余量。
    static func estimateSize(of word: String, fontSize: Double) -> CGSize {
        var width = 0.0
        for scalar in word.unicodeScalars {
            let isCJK = (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3000...0x303F).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
            width += isCJK ? fontSize : fontSize * 0.56
        }
        return CGSize(width: width + fontSize * 0.2, height: fontSize * 1.28)
    }

    private static func findFreeFrame(textSize: CGSize, center: CGPoint,
                                      canvas: CGSize, occupied: [CGRect]) -> CGRect? {
        var theta = 0.0
        let maxTheta = 40.0 * .pi
        while theta < maxTheta {
            let radius = 2.6 * theta
            let cx = center.x + CGFloat(radius * cos(theta))
            let cy = center.y + CGFloat(radius * sin(theta) * 0.62)  // 压扁纵向，横向更舒展
            let frame = CGRect(x: cx - textSize.width / 2, y: cy - textSize.height / 2,
                               width: textSize.width, height: textSize.height)
            if frame.minX >= 2, frame.minY >= 2,
               frame.maxX <= canvas.width - 2, frame.maxY <= canvas.height - 2,
               !occupied.contains(where: { $0.intersects(frame) }) {
                return frame
            }
            theta += 0.28
        }
        return nil
    }

    /// 按排名分配的颜色（同一份调色板用于 app 预览与 HTML 导出）。
    static func color(forRank rank: Int) -> String {
        let palette = [
            "#2563EB", "#0D9488", "#DC2626", "#7C3AED", "#D97706",
            "#0891B2", "#DB2777", "#4D7C0F", "#9333EA", "#B45309",
        ]
        return palette[rank % palette.count]
    }
}
