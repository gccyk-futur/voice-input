import XCTest

/// HistoryDateGroup 天分组逻辑单测：排序、天边界、跨时区稳定、坏时间戳归"今天"。
final class HistoryDateGroupTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let iso = ISO8601DateFormatter()

    private func date(_ s: String) -> Date { iso.date(from: s)! }

    private func item(ts: String, id: String = UUID().uuidString) -> HistoryItem {
        var it = HistoryItem(asrResult: id, llmResult: nil, engine: "system", llmEngine: nil)
        it.id = id
        it.timestamp = ts
        return it
    }

    func testGroupsByDayAndOrdersNewestFirst() {
        let now = date("2026-08-21T12:00:00Z")
        let items = [
            item(ts: "2026-08-21T09:00:00Z"),
            item(ts: "2026-08-20T20:00:00Z"),
            item(ts: "2026-08-21T10:00:00Z"),
        ]
        let sections = HistoryDateGroup.make(from: items, calendar: calendar, now: now)

        XCTAssertEqual(sections.count, 2)
        // 8-21 在前（更新的一天）
        XCTAssertEqual(calendar.startOfDay(for: sections[0].reference),
                       calendar.startOfDay(for: date("2026-08-21T00:00:00Z")))
        XCTAssertEqual(sections[0].items.count, 2)
        // 同一天内按时间降序
        XCTAssertEqual(sections[0].items[0].timestamp, "2026-08-21T10:00:00Z")
        XCTAssertEqual(sections[0].items[1].timestamp, "2026-08-21T09:00:00Z")
        XCTAssertEqual(sections[1].items.count, 1)
    }

    func testBadTimestampFallsIntoTodayBucket() {
        let now = date("2026-08-21T12:00:00Z")
        let items = [item(ts: "not-a-date")]
        let sections = HistoryDateGroup.make(from: items, calendar: calendar, now: now)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(calendar.startOfDay(for: sections[0].reference),
                       calendar.startOfDay(for: now))
        XCTAssertEqual(sections[0].items.count, 1)
    }

    func testEmptyInputYieldsEmptySections() {
        XCTAssertTrue(HistoryDateGroup.make(from: [], now: Date()).isEmpty)
    }
}
