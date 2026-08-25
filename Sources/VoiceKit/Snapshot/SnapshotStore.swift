import Foundation

/// 快照存储：独立的 snapshots.json，与历史解耦。
/// 提供 CRUD + 编辑，供「历史窗口的快照管理」和「速插浮层」两处共享读取。
@MainActor
final class SnapshotStore {
    static let shared = SnapshotStore()

    private let fileURL: URL
    private(set) var items: [SnapshotItem] = []

    /// 默认路径（Application Support/VoiceMate/snapshots.json）。
    convenience init() {
        self.init(fileURL: SnapshotStore.defaultURL())
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
        return support.appendingPathComponent("snapshots.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SnapshotItem].self, from: data) else { return }
        items = decoded
    }

    static let didChange = Notification.Name("VoiceMateSnapshotDidChange")

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 由一段文本创建快照（历史「加为快照」/ 速插浮层「新建」共用）。
    @discardableResult
    func add(text: String, label: String? = nil) -> SnapshotItem {
        let item = SnapshotItem(text: text, label: label)
        items.insert(item, at: 0)
        save()
        return item
    }

    /// 更新文本与可选标题；editedAt 刷新，条目移到最前（最近编辑优先）。
    func update(id: String, text: String, label: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text = text
        items[idx].label = label
        items[idx].editedAt = ISO8601DateFormatter().string(from: Date())
        let moved = items.remove(at: idx)
        items.insert(moved, at: 0)
        save()
    }

    func delete(_ item: SnapshotItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func delete(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }
}
