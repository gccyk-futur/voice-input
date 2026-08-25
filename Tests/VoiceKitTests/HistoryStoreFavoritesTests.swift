import XCTest

/// HistoryStore 收藏相关单测：批量取消收藏只移除标记、不删记录（历史窗口「收藏」标签的清除动作）。
@MainActor
final class HistoryStoreFavoritesTests: XCTestCase {

    private var store: HistoryStore!
    private var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json")
        store = HistoryStore(fileURL: tempURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func makeItem(_ text: String) -> HistoryItem {
        HistoryItem(asrResult: text, llmResult: nil, engine: "system", llmEngine: nil)
    }

    func testUnfavoriteAllKeepsRecordsAndClearsMarks() {
        let a = makeItem("甲")
        let b = makeItem("乙")
        let c = makeItem("丙")
        store.append(a); store.append(b); store.append(c)
        store.toggleFavorite(a); store.toggleFavorite(c)
        XCTAssertEqual(store.items.filter(\.favorite).count, 2)

        store.unfavoriteAll()

        XCTAssertEqual(store.items.count, 3, "记录必须保留")
        XCTAssertTrue(store.items.allSatisfy { !$0.favorite }, "收藏标记应全部移除")
    }

    func testUnfavoriteAllOnEmptyIsNoOp() {
        store.unfavoriteAll()
        XCTAssertTrue(store.items.isEmpty)
    }
}
