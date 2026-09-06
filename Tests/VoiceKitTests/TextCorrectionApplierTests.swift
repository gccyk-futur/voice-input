import XCTest

/// 本地词汇纠正引擎：拉丁词边界 / 大小写不敏感 / CJK 字面替换 / 长规则优先。
final class TextCorrectionApplierTests: XCTestCase {

    private func rule(_ match: String, _ replacement: String) -> CorrectionRule {
        CorrectionRule(match: match, replacement: replacement)
    }

    func testLatinPhraseCaseInsensitiveWholeWord() {
        let rules = [rule("cloud code", "Claude Code")]
        XCTAssertEqual(
            TextCorrectionApplier.apply("我们平常使用那个cloud code比较多", rules: rules),
            "我们平常使用那个Claude Code比较多")
        XCTAssertEqual(
            TextCorrectionApplier.apply("Cloud Code 和 CLOUD CODE", rules: rules),
            "Claude Code 和 Claude Code")
    }

    func testLatinWordBoundaryDoesNotAffectLongerWords() {
        let rules = [rule("cloud", "克劳德")]
        XCTAssertEqual(
            TextCorrectionApplier.apply("cloud computing and cloudy day", rules: rules),
            "克劳德 computing and cloudy day",
            "词边界必须保护 cloudy 这类更长的词")
    }

    func testCJKMatchIsLiteralReplace() {
        let rules = [rule("查特gp特", "ChatGPT")]
        XCTAssertEqual(
            TextCorrectionApplier.apply("我用查特gp特写代码", rules: rules),
            "我用ChatGPT写代码")
    }

    func testLongerRuleAppliesFirst() {
        // 若短规则先应用，"cloud code" 会先被改成 "云 code"，长规则就再也匹配不上
        let rules = [rule("cloud", "云"), rule("cloud code", "Claude Code")]
        XCTAssertEqual(
            TextCorrectionApplier.apply("cloud code", rules: rules),
            "Claude Code")
    }

    func testEmptyAndWhitespaceRulesAreSkipped() {
        let rules = [rule("", "x"), rule("  ", "y"), rule("a", "")]
        XCTAssertEqual(TextCorrectionApplier.apply("abc", rules: rules), "abc")
    }

    func testMultipleSpacesTolerated() {
        let rules = [rule("cloud code", "Claude Code")]
        XCTAssertEqual(
            TextCorrectionApplier.apply("cloud  code", rules: rules),
            "Claude Code",
            "口语识别空格数不稳定，应宽松匹配")
    }

    func testEmptyTextReturnsEmpty() {
        XCTAssertEqual(TextCorrectionApplier.apply("", rules: [rule("a", "b")]), "")
    }

    func testReplacementWithRegexSpecialCharsIsLiteral() {
        let rules = [rule("c++", "C Plus Plus")]
        XCTAssertEqual(
            TextCorrectionApplier.apply("i use c++ daily", rules: rules),
            "i use C Plus Plus daily")
    }
}
