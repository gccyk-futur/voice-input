import XCTest

final class XunfeiResultAssemblerTests: XCTestCase {
    func testEmptyAssembler() {
        let assembler = XunfeiResultAssembler()
        XCTAssertTrue(assembler.isEmpty)
        XCTAssertEqual(assembler.text, "")
    }

    func testAppendWithoutDynamicCorrection() {
        // 未开启 wpgs：pgs 为 nil，逐片追加
        var assembler = XunfeiResultAssembler()
        assembler.apply(sn: 1, fragment: "今天", pgs: nil, rg: nil)
        assembler.apply(sn: 2, fragment: "天气", pgs: nil, rg: nil)
        assembler.apply(sn: 3, fragment: "不错", pgs: nil, rg: nil)
        XCTAssertEqual(assembler.text, "今天天气不错")
    }

    func testOutOfOrderSnippetsAssembleInSnOrder() {
        var assembler = XunfeiResultAssembler()
        assembler.apply(sn: 2, fragment: "世界", pgs: nil, rg: nil)
        assembler.apply(sn: 1, fragment: "你好", pgs: nil, rg: nil)
        XCTAssertEqual(assembler.text, "你好世界")
    }

    func testApdBehavesLikePlainAppend() {
        var assembler = XunfeiResultAssembler()
        assembler.apply(sn: 1, fragment: "语音", pgs: "apd", rg: nil)
        assembler.apply(sn: 2, fragment: "输入", pgs: "apd", rg: nil)
        XCTAssertEqual(assembler.text, "语音输入")
    }

    func testRplReplacesRangeExceptSelf() {
        // 动态修正：sn=3 以 rpl 替换 [2,3]，被替换槽位清空，片段为整个范围的修正文本
        var assembler = XunfeiResultAssembler()
        assembler.apply(sn: 1, fragment: "科大", pgs: "apd", rg: nil)
        assembler.apply(sn: 2, fragment: "讯飞", pgs: "apd", rg: nil)
        assembler.apply(sn: 3, fragment: "讯飞听写", pgs: "rpl", rg: [2, 3])
        XCTAssertEqual(assembler.text, "科大讯飞听写")

        // 后续修正：sn=5 替换 [3,5]（覆盖到更早槽位）
        assembler.apply(sn: 4, fragment: "引擎", pgs: "apd", rg: nil)
        assembler.apply(sn: 5, fragment: "讯飞听写引擎", pgs: "rpl", rg: [3, 5])
        XCTAssertEqual(assembler.text, "科大讯飞听写引擎")
    }

    func testRplWithInvalidRangeFallsBackToAppend() {
        var assembler = XunfeiResultAssembler()
        assembler.apply(sn: 1, fragment: "甲", pgs: nil, rg: nil)
        // rg 缺失 / 逆序 / 空数组均不清空历史槽位
        assembler.apply(sn: 2, fragment: "乙", pgs: "rpl", rg: nil)
        assembler.apply(sn: 3, fragment: "丙", pgs: "rpl", rg: [3, 2])
        assembler.apply(sn: 4, fragment: "丁", pgs: "rpl", rg: [])
        XCTAssertEqual(assembler.text, "甲乙丙丁")
    }

    func testResetClearsAllSlots() {
        var assembler = XunfeiResultAssembler()
        assembler.apply(sn: 1, fragment: "内容", pgs: nil, rg: nil)
        XCTAssertFalse(assembler.isEmpty)
        assembler.reset()
        XCTAssertTrue(assembler.isEmpty)
        XCTAssertEqual(assembler.text, "")
    }
}
