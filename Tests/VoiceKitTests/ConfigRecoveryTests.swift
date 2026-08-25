import XCTest
@testable import VoiceKit

/// 配置防御：备份恢复 + 损坏隔离（ConfigFileRecovery / CorruptFileIsolator）。
/// 核心承诺：主配置损坏时用户数据（API Key、模型列表）不无声丢失。
final class ConfigRecoveryTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!
    private var backupURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("config.json")
        backupURL = tempDir.appendingPathComponent("config.backup.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeConfig(_ config: AppConfig, to url: URL) throws {
        var c = config
        c.general.maxHistoryCount = 88
        c.asr.aliyun.apiKey = "sk-should-survive"
        let data = try JSONEncoder().encode(c)
        try data.write(to: url)
    }

    private func writeGarbage(to url: URL) throws {
        try "{ not json at all ".write(to: url, atomically: true, encoding: .utf8)
    }

    /// 主文件正常：直接用，无恢复动作。
    func testValidMainLoadsWithoutRecovery() throws {
        try writeConfig(AppConfig(), to: fileURL)

        let (config, state) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)

        XCTAssertEqual(state, .none)
        XCTAssertEqual(config.general.maxHistoryCount, 88)
        XCTAssertEqual(config.asr.aliyun.apiKey, "sk-should-survive")
    }

    /// 首次启动（文件不存在）：默认配置，不算损坏、不触发恢复提示。
    func testMissingMainIsFreshInstallNotCorruption() {
        let (config, state) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)

        XCTAssertEqual(state, .none)
        XCTAssertEqual(config, AppConfig())
    }

    /// 主文件损坏 + 备份完好：从备份恢复，用户配置不丢，且主文件被回写修复。
    func testCorruptMainRestoresFromBackupAndRepairsMain() throws {
        try writeGarbage(to: fileURL)
        try writeConfig(AppConfig(), to: backupURL)

        let (config, state) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)

        XCTAssertEqual(state, .restoredFromBackup)
        XCTAssertEqual(config.general.maxHistoryCount, 88)
        XCTAssertEqual(config.asr.aliyun.apiKey, "sk-should-survive")

        // 主文件已被修复：再次读取无需备份
        let (reloaded, secondState) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)
        XCTAssertEqual(secondState, .none)
        XCTAssertEqual(reloaded.asr.aliyun.apiKey, "sk-should-survive")
    }

    /// 主文件损坏 + 无备份：隔离坏文件保留现场，默认配置启动。
    func testCorruptMainWithoutBackupIsolatesAndUsesDefaults() throws {
        try writeGarbage(to: fileURL)

        let (config, state) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)

        guard case .isolated(let corruptURL) = state else {
            return XCTFail("期望 .isolated，实际 \(state)")
        }
        XCTAssertEqual(config, AppConfig())
        // 原路径已让位，坏文件改名保留
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(corruptURL.lastPathComponent.hasPrefix("config.corrupt-"))
        XCTAssertEqual(corruptURL.pathExtension, "json")
        // 坏文件内容原样保留（现场可查）
        let preserved = try String(contentsOf: corruptURL, encoding: .utf8)
        XCTAssertEqual(preserved, "{ not json at all ")
    }

    /// 主备双坏：两份都隔离，默认配置启动。
    func testBothCorruptIsolatesBothFiles() throws {
        try writeGarbage(to: fileURL)
        try writeGarbage(to: backupURL)

        let (_, state) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)

        guard case .isolated = state else {
            return XCTFail("期望 .isolated，实际 \(state)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(leftovers.filter { $0.contains(".corrupt-") }.count, 2)
    }

    /// 隔离器：文件不存在时安全返回 nil。
    func testIsolatorIgnoresMissingFile() {
        XCTAssertNil(CorruptFileIsolator.isolate(fileURL))
    }

    /// 历史记录损坏同样隔离（HistoryStore.load 防御）。
    @MainActor
    func testHistoryStoreIsolatesCorruptFile() throws {
        let historyURL = tempDir.appendingPathComponent("history.json")
        try "corrupted".write(to: historyURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(fileURL: historyURL)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(leftovers.contains { $0.hasPrefix("history.corrupt-") })
    }
}
