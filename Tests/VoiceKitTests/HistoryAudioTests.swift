import XCTest

/// 历史语音留档：HistoryItem 新旧 JSON 兼容解码 + HistoryStore 删除/裁剪/清空时的音频清理闭环。
@MainActor
final class HistoryAudioTests: XCTestCase {

    private var tempAudioDir: URL!
    private var store: HistoryStore!
    private var tempJSON: URL!

    override func setUp() async throws {
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString)", isDirectory: true)
        AudioLibrary.testDirectoryOverride = tempAudioDir
        tempJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json")
        store = HistoryStore(fileURL: tempJSON)
    }

    override func tearDown() async throws {
        AudioLibrary.testDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempAudioDir)
        try? FileManager.default.removeItem(at: tempJSON)
    }

    // MARK: - 兼容解码

    func testOldJSONWithoutNewFieldsDecodes() throws {
        let oldJSON = """
        [{"id":"abc","timestamp":"2026-09-01T10:00:00Z","asrResult":"你好",
          "llmResult":null,"engine":"system","llmEngine":null,"favorite":false}]
        """
        let items = try JSONDecoder().decode([HistoryItem].self, from: Data(oldJSON.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].audioFile)
        XCTAssertNil(items[0].audioDuration)
        XCTAssertNil(items[0].asrRaw)
        XCTAssertEqual(items[0].asrResult, "你好")
    }

    func testNewFieldsRoundTrip() throws {
        var item = HistoryItem(asrResult: "纠正后", llmResult: nil,
                               engine: "xunfei", llmEngine: nil,
                               audioFile: "x.m4a", audioDuration: 3.2, asrRaw: "纠正前")
        item.favorite = true
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
        XCTAssertEqual(decoded[0].audioFile, "x.m4a")
        XCTAssertEqual(decoded[0].audioDuration ?? 0, 3.2, accuracy: 0.001)
        XCTAssertEqual(decoded[0].asrRaw, "纠正前")
    }

    // MARK: - 清理闭环

    private func makeAudioItem(_ text: String) -> HistoryItem {
        let item = HistoryItem(asrResult: text, llmResult: nil, engine: "system",
                               llmEngine: nil, audioFile: "\(UUID().uuidString).m4a")
        // 落一个真实文件，验证删除真的发生
        let url = AudioLibrary.url(forFile: item.audioFile!)!
        try? Data("fake".utf8).write(to: url)
        return item
    }

    func testRemoveDeletesAudioFile() {
        let item = makeAudioItem("要删的")
        store.append(item)
        XCTAssertTrue(AudioLibrary.fileExists(item.audioFile!))
        store.remove(item)
        XCTAssertFalse(AudioLibrary.fileExists(item.audioFile!), "删除历史必须连带删除语音")
    }

    func testClearDeletesAllAudioFiles() {
        let a = makeAudioItem("甲")
        let b = makeAudioItem("乙")
        store.append(a); store.append(b)
        store.clear()
        XCTAssertFalse(AudioLibrary.fileExists(a.audioFile!))
        XCTAssertFalse(AudioLibrary.fileExists(b.audioFile!))
    }

    func testEvictionByMaxCountDeletesAudioFile() {
        store.maxCount = 1
        let first = makeAudioItem("会被裁掉")
        store.append(first)
        let second = makeAudioItem("新来的")
        store.append(second)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertFalse(AudioLibrary.fileExists(first.audioFile!), "被上限裁剪的记录其语音必须删除")
        XCTAssertTrue(AudioLibrary.fileExists(second.audioFile!))
    }

    func testUpdateTranscriptionReplacesTextAndClearsPolish() {
        var item = HistoryItem(asrResult: "", llmResult: nil, engine: "system",
                               llmEngine: nil, audioFile: "keep.m4a")
        item.llmResult = "旧润色"
        store.append(item)
        store.updateTranscription(id: item.id, asrText: "补识别文本")
        XCTAssertEqual(store.items[0].asrResult, "补识别文本")
        XCTAssertNil(store.items[0].llmResult)
        XCTAssertEqual(store.items[0].audioFile, "keep.m4a", "语音留档必须保留")
    }

    // MARK: - AudioLibrary 路径安全

    func testURLForFileRejectsPathTraversal() {
        XCTAssertNil(AudioLibrary.url(forFile: "../evil.m4a"))
        XCTAssertNil(AudioLibrary.url(forFile: "a/b.m4a"))
        XCTAssertNil(AudioLibrary.url(forFile: ""))
        XCTAssertNotNil(AudioLibrary.url(forFile: "ok.m4a"))
    }
}
