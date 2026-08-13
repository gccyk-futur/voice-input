import Foundation

/// 使用统计的写入端：一次会话追加一行 JSON（JSONL），供将来的统计模块读取。
///
/// 为什么现在就写、界面以后再做：统计依赖历史数据，功能上线那天若没有存量，
/// 打开只会是一片空白。写入端很小，先让数据攒起来。
///
/// **这里不记录任何文字内容** —— 只有时长、字数、引擎名这类元数据，
/// 用户说过的话一个字都不会进入本文件。这是它与运行日志（含转录原文）的本质区别。
/// 文件仅存于本机，VoiceKit 没有服务器，不会上传。
///
/// 用 JSONL 而非单个 JSON 数组：追加一行即可，不必读出整个文件再重写，
/// 文件变大也不影响写入成本，导出时逐行读取同样简单。
final class UsageStatsStore: @unchecked Sendable {
    static let shared = UsageStatsStore()

    /// 超过此大小时截掉前半部分（保留较新的记录）。
    private static let maxBytes: UInt64 = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.voicemate.stats")
    let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("stats.jsonl")
    }

    // MARK: - 记录结构

    /// 语音识别阶段。
    struct ASRSegment: Codable {
        /// 引擎标识：system / aliyun / xunfei / deepgram
        var engine: String
        /// 录音时长（秒）
        var duration: Double
        /// 识别出的字符数（不是字节：中文一字三字节，字节数没有直观意义）
        var chars: Int
        /// 会话如何结束：manual（按热键）/ silence（静音超时）/ cancelled / failed
        var stopReason: String
        /// 从请求停止到引擎返回文本的耗时。撞满引擎的等待上限意味着尾部可能不完整——
        /// 这个字段正是为了让「丢字」这类问题可被统计发现，而不必翻日志找规律。
        var stopLatency: Double
    }

    /// AI 润色阶段。未开启润色时整段缺省 —— 与识别段分开，避免统计时被大量空值污染。
    struct LLMSegment: Codable {
        var model: String
        var template: String
        /// 服务端未返回 usage（如 Ollama）时为 nil
        var promptTokens: Int?
        var completionTokens: Int?
        var latency: Double
        var chars: Int
    }

    struct Record: Codable {
        /// 结构版本：将来读取端据此兼容旧数据
        var v: Int = 1
        var ts: String
        var asr: ASRSegment
        var llm: LLMSegment?
    }

    // MARK: - 写入

    /// 保留 n 位小数。浮点原样序列化会输出十几位小数——
    /// 录音时长精确到 10⁻¹⁵ 秒毫无意义，只是撑大文件、干扰阅读。
    private static func round(_ value: Double, _ places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (value * f).rounded() / f
    }

    func append(asr: ASRSegment, llm: LLMSegment?) {
        var asr = asr, llm = llm
        asr.duration = Self.round(asr.duration, 2)      // 10ms 分辨率足够
        asr.stopLatency = Self.round(asr.stopLatency, 3) // 毫秒级——丢字诊断要看这个
        if var l = llm { l.latency = Self.round(l.latency, 2); llm = l }
        let record = Record(ts: Self.timestamp(Date()), asr: asr, llm: llm)
        queue.async { [fileURL] in
            let encoder = JSONEncoder()
            // 键按字母序输出：JSON 本身无序，但稳定顺序便于人读与 diff。
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(record),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            guard let bytes = line.data(using: .utf8) else { return }

            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try? bytes.write(to: fileURL)
            } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: bytes)
            }
            Self.trimIfNeeded(fileURL)
        }
    }

    /// 超过上限时丢弃较早的一半，保持文件有界。按行截断，不会切出半条记录。
    private static func trimIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
              size > maxBytes,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 管理

    var fileSize: UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func clear() {
        queue.async { [fileURL] in try? FileManager.default.removeItem(at: fileURL) }
    }

    /// 导出到指定位置（原样复制 JSONL）。
    func export(to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
    }

    /// 每次调用新建：ISO8601DateFormatter 非 Sendable，做成静态属性会触发并发检查。
    /// 一次会话只格式化一次，开销可忽略。
    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
