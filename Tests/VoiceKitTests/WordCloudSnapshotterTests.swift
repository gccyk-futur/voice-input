import XCTest
@testable import VoiceKit

@MainActor
final class WordCloudSnapshotterTests: XCTestCase {

    private var tempDir: URL!
    private var savedProvider: () -> (enabled: Bool, threshold: Int, wordLimit: Int) = { (true, 5000, 60) }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicekit-wordcloud-tests-\(UUID().uuidString)", isDirectory: true)
        WordCloudSnapshotter.testDirectoryOverride = tempDir
        WordCloudSnapshotter.testCounterOverride = 0
        savedProvider = WordCloudSnapshotter.settingsProvider
    }

    override func tearDown() {
        WordCloudSnapshotter.testDirectoryOverride = nil
        WordCloudSnapshotter.testCounterOverride = nil
        WordCloudSnapshotter.settingsProvider = savedProvider
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 触发条件（纯函数）

    func testShouldTriggerOnlyWhenThresholdPositiveAndReached() {
        XCTAssertFalse(WordCloudSnapshotter.shouldTrigger(charsSince: 0, threshold: 0),
                       "阈值为 0 时永不触发，防止配 0 每条都切")
        XCTAssertFalse(WordCloudSnapshotter.shouldTrigger(charsSince: 100, threshold: 0))
        XCTAssertFalse(WordCloudSnapshotter.shouldTrigger(charsSince: 4999, threshold: 5000))
        XCTAssertTrue(WordCloudSnapshotter.shouldTrigger(charsSince: 5000, threshold: 5000))
        XCTAssertTrue(WordCloudSnapshotter.shouldTrigger(charsSince: 9000, threshold: 5000))
    }

    // MARK: - 累计与触发

    func testAccumulatesBelowThresholdWithoutSnapshot() {
        WordCloudSnapshotter.settingsProvider = { (true, 100, 60) }
        WordCloudSnapshotter.noteAppended(chars: 40)
        WordCloudSnapshotter.noteAppended(chars: 50)
        XCTAssertEqual(WordCloudSnapshotter.charsSinceSnapshot(), 90)
        XCTAssertTrue(WordCloudSnapshotter.list().isEmpty)
    }

    func testTriggersAndResetsCounterAtThreshold() {
        WordCloudSnapshotter.settingsProvider = { (true, 100, 60) }
        WordCloudSnapshotter.noteAppended(chars: 120)
        XCTAssertEqual(WordCloudSnapshotter.charsSinceSnapshot(), 0, "触发后计数器归零")
        XCTAssertEqual(WordCloudSnapshotter.list().count, 1)
    }

    func testDisabledSwitchSkipsAccumulation() {
        WordCloudSnapshotter.settingsProvider = { (false, 10, 60) }
        WordCloudSnapshotter.noteAppended(chars: 1000)
        XCTAssertEqual(WordCloudSnapshotter.charsSinceSnapshot(), 0)
        XCTAssertTrue(WordCloudSnapshotter.list().isEmpty)
    }

    // MARK: - 存储

    func testSnapshotPersistsAndDeletes() {
        let snapshot = WordCloudSnapshotter.generateSnapshot()
        let listed = WordCloudSnapshotter.list()
        XCTAssertEqual(listed.map(\.id), [snapshot.id])
        XCTAssertEqual(listed.first?.createdAt, snapshot.createdAt)

        WordCloudSnapshotter.delete(id: snapshot.id)
        XCTAssertTrue(WordCloudSnapshotter.list().isEmpty)
    }

    func testDeleteRejectsPathTraversal() {
        let snapshot = WordCloudSnapshotter.generateSnapshot()
        WordCloudSnapshotter.delete(id: "../\(snapshot.id)")
        XCTAssertEqual(WordCloudSnapshotter.list().count, 1, "含路径分隔符的 id 必须被拒绝")
    }

    func testListSortedNewestFirst() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let older = WordCloudSnapshot(id: "a", createdAt: "2026-09-01T00:00:00Z", sourceCount: 1,
                                      words: [.init(word: "旧", count: 2)])
        let newer = WordCloudSnapshot(id: "b", createdAt: "2026-09-05T00:00:00Z", sourceCount: 1,
                                      words: [.init(word: "新", count: 2)])
        let enc = JSONEncoder()
        try enc.encode(older).write(to: tempDir.appendingPathComponent("a.json"))
        try enc.encode(newer).write(to: tempDir.appendingPathComponent("b.json"))
        XCTAssertEqual(WordCloudSnapshotter.list().map(\.id), ["b", "a"])
    }
}
