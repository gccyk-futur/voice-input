import Foundation

/// 历史语音留档的文件管理：Application Support/VoiceMate/audio/<itemID>.m4a。
/// 生命周期与历史记录绑定——删除/裁剪/清空历史时对应语音一并删除（见 HistoryStore）。
enum AudioLibrary {

    /// 测试专用目录覆盖：单测写入真实 Application Support 会误删用户留档，必须隔离。
    /// 仅测试 target 设置；生产代码永远为 nil。
    nonisolated(unsafe) static var testDirectoryOverride: URL?

    /// 留档目录（不存在时创建）。
    static func directory() -> URL {
        if let override = testDirectoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// 为一次新会话生成留档 URL（文件名即后来的 HistoryItem.id）。
    static func newRecordingURL(itemID: String) -> URL {
        directory().appendingPathComponent("\(itemID).m4a")
    }

    /// 由留档文件名还原完整路径；文件名非法（含路径分隔符）时拒绝拼接，防目录穿越。
    static func url(forFile file: String) -> URL? {
        guard !file.isEmpty, !file.contains("/"), !file.contains("\\") else { return nil }
        return directory().appendingPathComponent(file)
    }

    static func fileExists(_ file: String) -> Bool {
        guard let url = url(forFile: file) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func delete(file: String?) {
        guard let file, let url = url(forFile: file) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 清空全部留档（历史「清空全部」时调用）。
    static func deleteAll() {
        let dir = directory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files where name.hasSuffix(".m4a") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 当前留档占用的磁盘字节数（含目录项开销忽略不计）。
    static func totalBytes() -> Int64 {
        let dir = directory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for name in files where name.hasSuffix(".m4a") {
            let url = dir.appendingPathComponent(name)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 清除「历史里已不存在」的孤儿留档（例如 2.0 之前写入的历史无此机制时的残留）。
    static func pruneOrphans(keeping validFiles: Set<String>) {
        let dir = directory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files where name.hasSuffix(".m4a") && !validFiles.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
