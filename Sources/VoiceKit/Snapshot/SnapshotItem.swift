import Foundation

/// 快照：用户主动保存的可复用文本片段，独立于历史时间线。
///
/// 与历史/收藏的区别：
/// - 历史 = 自动转录、可裁剪、有时间线
/// - 收藏 = 历史条目上的一个标记（favorite），不独立存储
/// - 快照 = 独立保存的片段，用户手动管理，永不自动清理，可编辑
struct SnapshotItem: Codable, Identifiable, Equatable {
    var id: String
    var createdAt: String
    /// 快照文本内容。
    var text: String
    /// 可选标题（便于速插时辨认）；为空时展示文本前若干字。
    var label: String?
    /// 最近一次编辑时间（用于管理列表排序）。
    var editedAt: String

    init(text: String, label: String? = nil) {
        let now = ISO8601DateFormatter().string(from: Date())
        self.id = UUID().uuidString
        self.createdAt = now
        self.text = text
        self.label = label
        self.editedAt = now
    }
}
