import Foundation

/// 一张词云快照：某一时刻历史记录的高频词切片。
/// 只存词频聚合（词 + 次数），不含句子原文——隐私上没有超出 history.json 的增量。
struct WordCloudSnapshot: Codable, Equatable, Identifiable {
    struct WordCount: Codable, Equatable {
        var word: String
        var count: Int
    }
    var id: String
    /// ISO8601 时间戳
    var createdAt: String
    /// 生成时基于的历史条数
    var sourceCount: Int
    var words: [WordCount]
}

/// 词云快照：锚定触发（每累计 N 个新增识别字自动切一张）+ 本地存储。
/// 文件：Application Support/VoiceMate/wordcloud/<id>.json；
/// 「距上一张快照的新增字数」计数器在 UserDefaults（重启不丢）。
/// 选锚定触发而非定时器：几天不用不会攒下一堆重复/空快照，每张都有新增内容。
@MainActor
enum WordCloudSnapshotter {

    static let didChange = Notification.Name("VoiceKit.WordCloudSnapshotDidChange")

    /// 快照保留上限：超过后删最旧，避免无界增长。
    static let maxSnapshots = 100

    private static let counterKey = "voicekit.wordcloud.charsSinceSnapshot"

    /// 配置读取口（开关 + 阈值 + 词数上限）。app 侧由 ConfigStore 注入真实读取；测试注入固定值。
    /// 存在是为了让本模块不反向依赖 ConfigStore（保持可单测、测试 target 不用拖入 AppKit 依赖链）。
    static var settingsProvider: () -> (enabled: Bool, threshold: Int, wordLimit: Int) = { (true, 5000, 60) }

    /// 测试专用目录覆盖：单测写入真实 Application Support 会污染用户数据，必须隔离。
    nonisolated(unsafe) static var testDirectoryOverride: URL?
    /// 测试专用计数器覆盖：非 nil 时读写都走它，不碰真实 UserDefaults。
    nonisolated(unsafe) static var testCounterOverride: Int?

    // MARK: - 触发

    /// 历史新增一条时由 HistoryStore.append 调用：累计字数，过阈值就切一张快照。
    static func noteAppended(chars: Int) {
        let cfg = settingsProvider()
        guard cfg.enabled else { return }
        let total = charsSinceSnapshot() + max(0, chars)
        if shouldTrigger(charsSince: total, threshold: cfg.threshold) {
            generateSnapshot()
            setCounter(0)
        } else {
            setCounter(total)
        }
    }

    /// 纯函数：是否达到触发条件（阈值必须为正，防止配 0 时每条都触发）。
    static func shouldTrigger(charsSince: Int, threshold: Int) -> Bool {
        threshold > 0 && charsSince >= threshold
    }

    static func charsSinceSnapshot() -> Int {
        testCounterOverride ?? UserDefaults.standard.integer(forKey: counterKey)
    }

    private static func setCounter(_ value: Int) {
        if testCounterOverride != nil {
            testCounterOverride = value
        } else {
            UserDefaults.standard.set(value, forKey: counterKey)
        }
    }

    // MARK: - 生成

    /// 立即生成一张快照（锚定触发与设置页「立即生成」共用同一出口）。
    @discardableResult
    static func generateSnapshot() -> WordCloudSnapshot {
        let texts = HistoryStore.shared.items
            .map { $0.llmResult ?? $0.asrResult }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let top = WordFrequencyAnalyzer.topWords(from: texts, limit: max(10, settingsProvider().wordLimit))
        let snapshot = WordCloudSnapshot(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            sourceCount: texts.count,
            words: top.map { WordCloudSnapshot.WordCount(word: $0.word, count: $0.count) }
        )
        save(snapshot)
        return snapshot
    }

    // MARK: - 存储

    static func directory() -> URL {
        if let override = testDirectoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
            .appendingPathComponent("wordcloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// 全部快照，新的在前。
    static func list() -> [WordCloudSnapshot] {
        let dir = directory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> WordCloudSnapshot? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                return try? JSONDecoder().decode(WordCloudSnapshot.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(id: String) {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\") else { return }
        try? FileManager.default.removeItem(at: directory().appendingPathComponent("\(id).json"))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func deleteAll() {
        let dir = directory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files where name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 快照总占用（数据隐私页披露用）。
    static func totalBytes() -> Int64 {
        let dir = directory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for name in files where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func save(_ snapshot: WordCloudSnapshot) {
        let dir = directory()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: dir.appendingPathComponent("\(snapshot.id).json"), options: .atomic)
        // 超上限删最旧
        let all = list()
        if all.count > maxSnapshots {
            for old in all.suffix(from: maxSnapshots) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(old.id).json"))
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
