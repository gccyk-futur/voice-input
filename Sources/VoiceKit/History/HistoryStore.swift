import Foundation

/// 本地历史记录存储：JSON 文件，最近 maxCount 条，收藏项受保护不被自动清理。
/// 防御：文件存在但解不开时隔离为 history.corrupt-<时间戳>.json 保留现场（绝不删除）。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let fileURL: URL
    private(set) var items: [HistoryItem] = []
    var maxCount: Int = 20
    var historyDisabled: Bool = false

    /// 默认路径（Application Support/VoiceMate/history.json）。
    convenience init() {
        self.init(fileURL: HistoryStore.defaultURL())
    }

    /// 可注入路径，供单测隔离。
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    private static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("history.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            // 文件存在但损坏：隔离保留现场，而不是沉默地从空历史重新开始
            CorruptFileIsolator.isolate(fileURL)
            print("[HistoryStore] history.json 损坏，已隔离原文件并从头开始")
            return
        }
        items = decoded
    }

    /// 历史变更通知（HistoryView 据此刷新）。
    static let didChange = Notification.Name("VoiceMateHistoryDidChange")

    func save() {
        guard !historyDisabled else { return }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func append(_ item: HistoryItem) {
        guard !historyDisabled else { return }
        items.insert(item, at: 0)
        let favorites = items.filter { $0.favorite }
        let nonFavorites = items.filter { !$0.favorite }
        let kept = Array(nonFavorites.prefix(max(0, maxCount - favorites.count)))
        // 被上限裁剪掉的记录，其语音留档一并删除，避免磁盘只涨不消
        let evicted = items.filter { old in !kept.contains(where: { $0.id == old.id }) && !old.favorite }
        for item in evicted { AudioLibrary.delete(file: item.audioFile) }
        items = kept + favorites
        save()
        // 词云锚定快照：按识别原文字数累计，过阈值自动切一张（仅词频，不含原文）
        WordCloudSnapshotter.noteAppended(chars: item.asrResult.count)
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        AudioLibrary.delete(file: item.audioFile)
        save()
    }

    func toggleFavorite(_ item: HistoryItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].favorite.toggle()
            save()
        }
    }

    /// 取消全部收藏：记录保留在「全部」中，仅移除收藏标记。
    func unfavoriteAll() {
        guard items.contains(where: \.favorite) else { return }
        for idx in items.indices { items[idx].favorite = false }
        save()
    }

    func clear() {
        items.removeAll()
        AudioLibrary.deleteAll()
        save()
    }

    /// 用「重新识别」的结果更新某条记录：替换识别文本、清掉旧的润色与纠正对照，
    /// 语音留档保留（仍可回放对照）。
    func updateTranscription(id: String, asrText: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].asrResult = asrText
        items[idx].llmResult = nil
        items[idx].llmEngine = nil
        items[idx].asrRaw = nil
        save()
    }
}
