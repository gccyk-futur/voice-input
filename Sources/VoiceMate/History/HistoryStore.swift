import Foundation

/// 本地历史记录存储：JSON 文件，最近 maxCount 条，收藏项受保护不被自动清理。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let fileURL: URL
    private(set) var items: [HistoryItem] = []
    var maxCount: Int = 20
    var historyDisabled: Bool = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("history.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = decoded
    }

    func save() {
        guard !historyDisabled else { return }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func append(_ item: HistoryItem) {
        guard !historyDisabled else { return }
        items.insert(item, at: 0)
        let favorites = items.filter { $0.favorite }
        let nonFavorites = items.filter { !$0.favorite }
        items = Array(nonFavorites.prefix(max(0, maxCount - favorites.count))) + favorites
        save()
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func toggleFavorite(_ item: HistoryItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].favorite.toggle()
            save()
        }
    }

    func clear() {
        items.removeAll()
        save()
    }
}
