import Foundation

/// 轻量文件日志：写入 `~/Library/Logs/VoiceKit/voicekit.log`，同时镜像到 stdout。
///
/// 为什么需要：app 从 Finder/LaunchAgent 启动时 stdout 无人接收，`print` 等于石沉大海；
/// 用户遇到"它有时候不好使"时，这份日志是唯一的排查线索。
///
/// - 串行队列保证线程安全（AVAudioEngine 的 tap 回调、WebSocket 回调、主线程都会写）。
/// - 文件超过 `maxBytes` 时自动截断，避免无限增长。
/// - 不引入任何第三方依赖。
enum Log {
    private static let queue = DispatchQueue(label: "com.voicemate.log")
    /// 供设置页展示与清空（本地数据一览）。
    static var currentFileURL: URL? { fileURL }

    /// 清空日志文件。
    static func clear() {
        queue.async {
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let fileURL: URL? = {
        let fm = FileManager.default
        guard let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/VoiceKit", isDirectory: true) else { return nil }
        do {
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            return logs.appendingPathComponent("voicekit.log")
        } catch {
            return nil
        }
    }()
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }
    static func debug(_ message: String) {
        #if DEBUG
        write("DEBUG", message)
        #endif
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(dateFormatter.string(from: Date())) \(level) \(message)\n"
        // 始终输出到 stdout，方便 Xcode/Console.app 实时查看
        print(line, terminator: "")
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            // 超过大小上限则截断重写
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64, size > maxBytes {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
