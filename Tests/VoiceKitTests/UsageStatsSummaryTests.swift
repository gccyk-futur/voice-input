import XCTest

/// UsageStatsSummary 聚合逻辑单测：周界、坏行、去重、排序均为确定性断言。
final class UsageStatsSummaryTests: XCTestCase {

    private let calendar = Calendar.current

    /// 参照时间：2026-08-21 12:00（周五）。构造“本周”与“上周”记录用。
    private lazy var now: Date = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!

    private func recordJSON(
        ts: String,
        engine: String = "system",
        duration: Double = 10,
        chars: Int = 30,
        stopReason: String = "manual",
        stopLatency: Double = 0.5,
        llmChars: Int? = nil
    ) -> String {
        let llmPart: String
        if let llmChars {
            llmPart = """
            ,"llm":{"model":"gpt","template":"default","promptTokens":10,"completionTokens":5,\
            "firstTokenLatency":0.2,"latency":1.0,"chars":\(llmChars)}
            """
        } else {
            llmPart = ""
        }
        return """
        {"v":1,"ts":"\(ts)","asr":{"engine":"\(engine)","duration":\(duration),"chars":\(chars),\
        "stopReason":"\(stopReason)","stopLatency":\(stopLatency)}\(llmPart)}
        """
    }

    func testEmptyInputYieldsEmptySummary() {
        let summary = UsageStatsSummary.make(fromJSONL: "", now: now)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertTrue(summary.engineLatencies.isEmpty)
        XCTAssertTrue(summary.engines.isEmpty)
        XCTAssertTrue(summary.stopReasons.isEmpty)
    }

    func testAggregatesLifetimeAndWeekSeparately() throws {
        // 本周两条 + 上周一条
        let jsonl = [
            recordJSON(ts: "2026-08-20T09:00:00Z", duration: 30, chars: 100),
            recordJSON(ts: "2026-08-19T18:00:00Z", duration: 20, chars: 50, llmChars: 40),
            recordJSON(ts: "2026-08-10T10:00:00Z", duration: 60, chars: 200),
        ].joined(separator: "\n")

        let summary = UsageStatsSummary.make(fromJSONL: jsonl, now: now, calendar: calendar)

        XCTAssertEqual(summary.lifetime.sessions, 3)
        XCTAssertEqual(summary.lifetime.duration, 110, accuracy: 0.001)
        XCTAssertEqual(summary.lifetime.chars, 100 + 50 + 40 + 200)
        XCTAssertEqual(summary.lifetime.days, 3)
        // 仅中间一条带 llm 段
        XCTAssertEqual(summary.llmSessions, 1)
        XCTAssertEqual(summary.llmChars, 40)
        XCTAssertEqual(summary.llmTokens, 10 + 5)

        XCTAssertEqual(summary.week.sessions, 2)
        XCTAssertEqual(summary.week.duration, 50, accuracy: 0.001)
        XCTAssertEqual(summary.week.days, 2)
    }

    func testSameDayRecordsDeduplicateDayCount() {
        let jsonl = [
            recordJSON(ts: "2026-08-20T09:00:00Z"),
            recordJSON(ts: "2026-08-20T15:00:00Z"),
            recordJSON(ts: "2026-08-20T21:00:00Z"),
        ].joined(separator: "\n")

        let summary = UsageStatsSummary.make(fromJSONL: jsonl, now: now, calendar: calendar)
        XCTAssertEqual(summary.lifetime.sessions, 3)
        XCTAssertEqual(summary.lifetime.days, 1)
    }

    func testMalformedLinesAreSkippedButCounted() {
        let jsonl = """
        not-json-at-all
        \(recordJSON(ts: "2026-08-20T09:00:00Z"))
        {"v":1,"broken":
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        let summary = UsageStatsSummary.make(fromJSONL: jsonl, now: now, calendar: calendar)
        XCTAssertEqual(summary.totalLines, 3)
        XCTAssertEqual(summary.lifetime.sessions, 1)
    }

    func testEngineAndStopReasonSharesSortDescending() {
        let jsonl = [
            recordJSON(ts: "2026-08-20T09:00:00Z", engine: "aliyun"),
            recordJSON(ts: "2026-08-20T10:00:00Z", engine: "system"),
            recordJSON(ts: "2026-08-21T10:00:00Z", engine: "aliyun", stopReason: "silence"),
            recordJSON(ts: "2026-08-21T11:00:00Z", engine: "deepgram", stopReason: "cancelled"),
        ].joined(separator: "\n")

        let summary = UsageStatsSummary.make(fromJSONL: jsonl, now: now, calendar: calendar)

        XCTAssertEqual(summary.engines.map(\.name), ["aliyun", "deepgram", "system"])
        XCTAssertEqual(summary.engines.first?.count, 2)
        // 同票数时按名称字母序，保证展示顺序确定性
        XCTAssertEqual(summary.stopReasons.map(\.name), ["manual", "cancelled", "silence"])
    }

    func testEngineLatencyGroupsPerEngineAndSortsDescending() {
        let jsonl = [
            recordJSON(ts: "2026-08-20T09:00:00Z", engine: "aliyun", stopLatency: 0.2),
            recordJSON(ts: "2026-08-20T10:00:00Z", engine: "xunfei", stopLatency: 0.8),
            recordJSON(ts: "2026-08-21T10:00:00Z", engine: "aliyun", stopLatency: 0.6),
        ].joined(separator: "\n")

        let summary = UsageStatsSummary.make(fromJSONL: jsonl, now: now, calendar: calendar)
        XCTAssertEqual(summary.engineLatencies.map(\.engine), ["xunfei", "aliyun"])
        XCTAssertEqual(summary.engineLatencies[0].seconds, 0.8, accuracy: 0.0001)
        XCTAssertEqual(summary.engineLatencies[1].seconds, 0.4, accuracy: 0.0001)
    }
}
