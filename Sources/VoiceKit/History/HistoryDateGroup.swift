import Foundation

/// 历史记录按「天」分组，供浏览时形成轨迹感（今天 / 昨天 / 具体日期）。
///
/// 纯函数：输入 [HistoryItem] 与参考时间，输出按天分组的区块（降序）。
/// 头部文案由视图层用注入的 headerProvider 决定，便于单测时不依赖本地化。
enum HistoryDateGroup {

    struct Section {
        /// 该天内所有记录所在日期（当天 00:00），作为分组键。
        let reference: Date
        let items: [HistoryItem]
    }

    /// - Parameters:
    ///   - items: 待分组的记录（任意顺序，内部按 timestamp 降序重排）
    ///   - calendar: 用于计算“天”的边界
    ///   - now: “今天”的参照；测试可注入固定值
    static func make(
        from items: [HistoryItem],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [Section] {
        let decoder = ISO8601DateFormatter()
        let sorted = items
            .sorted { lhs, rhs in
                (decoder.date(from: lhs.timestamp) ?? .distantPast)
                    > (decoder.date(from: rhs.timestamp) ?? .distantPast)
            }

        // 以「天的起始」为键分组；保持从新到旧
        var order: [Date] = []
        var buckets: [Date: [HistoryItem]] = [:]
        for item in sorted {
            guard let date = decoder.date(from: item.timestamp) else {
                let key = calendar.startOfDay(for: now)
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(item)
                continue
            }
            let key = calendar.startOfDay(for: date)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }

        return order.map { Section(reference: $0, items: buckets[$0] ?? []) }
    }
}
