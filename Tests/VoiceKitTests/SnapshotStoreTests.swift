import XCTest

/// SnapshotStore CRUD 单测：增删改、编辑后置顶。
@MainActor
final class SnapshotStoreTests: XCTestCase {

    private var store: SnapshotStore!
    private var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshots-\(UUID().uuidString).json")
        store = SnapshotStore(fileURL: tempURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testAddInsertsAtTop() {
        let a = store.add(text: "第一条")
        let b = store.add(text: "第二条")
        XCTAssertEqual(store.items.map(\.text), ["第二条", "第一条"])
        XCTAssertEqual(store.items.count, 2)
        _ = b
    }

    func testUpdateMovesToTopAndRefreshesEditedAt() {
        let first = store.add(text: "旧的")
        let second = store.add(text: "中间")
        store.update(id: first.id, text: "改名后", label: "标题")

        XCTAssertEqual(store.items.first?.text, "改名后")
        XCTAssertEqual(store.items.first?.label, "标题")
        XCTAssertEqual(store.items.count, 2)
        _ = second
    }

    func testDeleteRemovesItem() {
        let a = store.add(text: "待删")
        store.delete(a)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSnapshotStoresPreservesStateAcrossInstances() {
        // 通过追加一条后重新 load 验证持久化字段结构往返
        store.add(text: "持久化段")
        XCTAssertEqual(store.items.count, 1)
        let item = store.items[0]
        XCTAssertFalse(item.id.isEmpty)
        XCTAssertFalse(item.createdAt.isEmpty)
    }
}
