import Foundation

/// 使用统计的读取端：把 stats.jsonl 的原始行聚合成面板可展示的摘要。
///
/// 与写入端（UsageStatsStore）一样只处理元数据 —— 时长、字数、引擎名，
/// 不含任何语音内容。聚合是纯函数：输入 JSONL 行与当前时间，输出确定性结果，
/// 便于单测覆盖周界、坏行、空数据等情形。
enum UsageStatsSummary {

    // MARK: - 结果模型

    struct Overview: Equatable {
        var days: Int = 0
        var sessions: Int = 0
        var duration: Double = 0
        var chars: Int = 0

        static let empty = Overview()
    }

    struct CategoryShare: Equatable {
        let name: String
        let count: Int
    }

    /// 按引擎分组的平均出稿耗时（秒）；用于对照哪个引擎慢。
    struct EngineLatency: Equatable {
        let engine: String
        let seconds: Double
    }

    struct Summary: Equatable {
        var lifetime = Overview.empty
        var week = Overview.empty
        /// 按会话数降序；仅含有会话的引擎。
        var engines: [CategoryShare] = []
        /// 按次数降序；manual / silence / cancelled / failed。
        var stopReasons: [CategoryShare] = []
        /// 开启了 AI 润色的会话数。
        var llmSessions = 0
        /// 润色结果的字数（不含识别原文）。
        var llmChars = 0
        /// 服务商返回的 token 总量（prompt + completion）；Ollama 等未返回 usage 时按 0 计。
        var llmTokens = 0
        /// 按引擎分组的平均出稿耗时，按耗时降序；无会话时为 []。
        var engineLatencies: [EngineLatency] = []
        /// 解析的总行数（含无法解析的行），供调试展示。
        var totalLines = 0
        var isEmpty: Bool { lifetime.sessions == 0 }
    }

    // MARK: - 聚合入口

    /// - Parameters:
    ///   - jsonl: stats.jsonl 的全部文本（每行一条 JSON 记录）
    ///   - now: “本周”的参照时间；测试可注入固定值
    static func make(fromJSONL jsonl: String, now: Date, calendar: Calendar = .current) -> Summary {
        let decoder = JSONDecoder()
        var result = Summary()
        var engineCounts: [String: Int] = [:]
        var reasonCounts: [String: Int] = [:]
        // 天数按 ISO8601 时间戳的日期前缀（YYYY-MM-DD）去重：统计口径无需严格时区换算，
        // 且与写入端统一使用同一格式，行为稳定可预期。
        var lifetimeDayKeys = Set<String>()
        var weekDayKeys = Set<String>()
        var stopLatencySum: [String: Double] = [:]
        var stopLatencyCount: [String: Int] = [:]

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            result.totalLines += 1
            guard let data = String(line).data(using: .utf8),
                  let record = try? decoder.decode(UsageStatsStore.Record.self, from: data) else {
                continue // 坏行跳过：统计展示宁可少算也不报错打断用户
            }
            let dayKey = String(record.ts.prefix(10))
            let inWeek = ISO8601DateFormatter().date(from: record.ts)
                .map { calendar.isDate($0, equalTo: now, toGranularity: .weekOfYear) } ?? false

            result.lifetime.sessions += 1
            result.lifetime.duration += record.asr.duration
            result.lifetime.chars += record.asr.chars
            lifetimeDayKeys.insert(dayKey)

            if inWeek {
                result.week.sessions += 1
                result.week.duration += record.asr.duration
                result.week.chars += record.asr.chars
                weekDayKeys.insert(dayKey)
            }

            engineCounts[record.asr.engine, default: 0] += 1
            reasonCounts[record.asr.stopReason, default: 0] += 1
            stopLatencySum[record.asr.engine, default: 0] += record.asr.stopLatency
            stopLatencyCount[record.asr.engine, default: 0] += 1

            if let llm = record.llm {
                result.llmSessions += 1
                result.llmChars += llm.chars
                result.llmTokens += (llm.promptTokens ?? 0) + (llm.completionTokens ?? 0)
                result.lifetime.chars += llm.chars
                if inWeek { result.week.chars += llm.chars }
            }
        }

        result.lifetime.days = lifetimeDayKeys.count
        result.week.days = weekDayKeys.count
        result.engines = engineCounts
            .map { CategoryShare(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        result.stopReasons = reasonCounts
            .map { CategoryShare(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        if !stopLatencyCount.isEmpty {
            result.engineLatencies = stopLatencySum
                .filter { (stopLatencyCount[$0.key] ?? 0) > 0 }
                .map { EngineLatency(engine: $0.key, seconds: $0.value / Double(stopLatencyCount[$0.key] ?? 1)) }
                .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.engine < $1.engine }
        }
        return result
    }
}
