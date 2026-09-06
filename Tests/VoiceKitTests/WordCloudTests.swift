import XCTest

/// 历史词云纯逻辑：词频统计（停用词 / 单字 / 大小写归并）、确定性布局、HTML 导出。
final class WordCloudTests: XCTestCase {

    // MARK: - 词频统计

    func testStopwordsAndShortTokensFiltered() {
        let texts = ["就是就是这个那个这个可以可以", "the and or but"]
        let words = WordFrequencyAnalyzer.topWords(from: texts)
        let tokens = words.map(\.word)
        XCTAssertFalse(tokens.contains("就是"))
        XCTAssertFalse(tokens.contains("这个"))
        XCTAssertFalse(tokens.contains("the"))
    }

    func testLatinLowercasedAndMerged() {
        let texts = ["Claude claude CLAUDE claude"]
        let words = WordFrequencyAnalyzer.topWords(from: texts)
        XCTAssertEqual(words.first?.word, "claude")
        XCTAssertEqual(words.first?.count, 4)
    }

    func testSingleCJKCharDropped() {
        let texts = ["好 好 好 天气 天气"]
        let tokens = WordFrequencyAnalyzer.topWords(from: texts).map(\.word)
        XCTAssertFalse(tokens.contains("好"), "单字噪音大，应丢弃")
    }

    func testResultsSortedByCountDesc() {
        // 4/3/2 次：按计数降序（单次出现的 2 字词会被过滤，见 topWords 规则）
        let texts = ["苹果 苹果 苹果 苹果 橘子 橘子 橘子 香蕉 香蕉"]
        let words = WordFrequencyAnalyzer.topWords(from: texts)
        XCTAssertEqual(words.map(\.word), ["苹果", "橘子", "香蕉"])
    }

    // MARK: - 布局

    private let canvas = CGSize(width: 660, height: 380)

    func testLayoutDeterministicAndNonOverlapping() {
        let words = [("语音", 30), ("识别", 22), ("历史", 15), ("记录", 10), ("引擎", 6), ("claude", 4)]
        let a = WordCloudLayout.place(words, in: canvas)
        let b = WordCloudLayout.place(words, in: canvas)
        XCTAssertEqual(a, b, "同一输入必须得到同一布局（预览与导出一致）")

        for i in a.indices {
            for j in a.indices where j > i {
                XCTAssertFalse(
                    a[i].frame.insetBy(dx: -1, dy: -1).intersects(a[j].frame.insetBy(dx: -1, dy: -1)),
                    "词框不得重叠：\(a[i].word) vs \(a[j].word)")
            }
            XCTAssertTrue(canvas.contains(a[i].frame), "\(a[i].word) 必须在画布内")
        }
    }

    func testBiggerCountGetsBiggerFont() {
        let placed = WordCloudLayout.place([("大词", 100), ("小词", 1)], in: canvas)
        let big = placed.first { $0.word == "大词" }
        let small = placed.first { $0.word == "小词" }
        XCTAssertNotNil(big)
        XCTAssertNotNil(small)
        XCTAssertGreaterThan(big!.fontSize, small!.fontSize)
    }

    func testEmptyInputProducesEmptyLayout() {
        XCTAssertTrue(WordCloudLayout.place([], in: canvas).isEmpty)
    }

    // MARK: - HTML 导出

    func testHTMLContainsWordsAndEscapesSpecialChars() {
        let words = [("语音", 10), ("a<b", 5)]
        let placed = WordCloudLayout.place(words, in: canvas)
        let html = WordCloudHTMLExporter.export(placed: placed, canvas: canvas, sourceCount: 3)
        XCTAssertTrue(html.contains("语音"))
        XCTAssertTrue(html.contains("a&lt;b"), "HTML 必须转义特殊字符")
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertFalse(html.contains("a<b>"))
    }
}

private extension CGSize {
    func contains(_ rect: CGRect) -> Bool {
        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= width && rect.maxY <= height
    }
}
