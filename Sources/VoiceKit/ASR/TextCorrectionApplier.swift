import Foundation

/// 一条词汇纠正规则：把 ASR 容易听错的 `match` 替换为 `replacement`。
/// 例：match "cloud code" → replacement "Claude Code"。
struct CorrectionRule: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var match: String = ""
    var replacement: String = ""

    /// 宽容解码：手工编辑 config.json 缺 key 时回退默认值，不致整个 correction 解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        match = (try? c.decodeIfPresent(String.self, forKey: .match)) ?? ""
        replacement = (try? c.decodeIfPresent(String.self, forKey: .replacement)) ?? ""
    }

    init(id: String = UUID().uuidString, match: String = "", replacement: String = "") {
        self.id = id
        self.match = match
        self.replacement = replacement
    }
}

/// 词汇纠正配置：引擎无关，对所有 ASR 引擎的最终结果统一生效。
struct CorrectionConfig: Codable, Equatable {
    var enabled: Bool = true
    var rules: [CorrectionRule] = []

    /// 宽容解码：旧版 config.json 无 correction key 或缺字段时回退默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        rules = (try? c.decodeIfPresent([CorrectionRule].self, forKey: .rules)) ?? []
    }

    init(enabled: Bool = true, rules: [CorrectionRule] = []) {
        self.enabled = enabled
        self.rules = rules
    }
}

/// 识别后文本纠正：在 ASR 最终结果进 LLM 润色 / 粘贴 / 历史之前应用用户自定义替换规则。
///
/// 设计要点：
/// - 纯拉丁 match（如 "cloud code"）按「词边界 + 大小写不敏感」匹配——
 ///  避免把 cloudy 里的 cloud 也改掉；
/// - 含 CJK 的 match 按字面替换（中文没有词边界概念，用户写的就是要换的）；
/// - 规则按 match 长度降序应用，防止短规则抢先吃掉长规则的前缀。
enum TextCorrectionApplier {

    /// 对一段识别文本应用全部规则，返回纠正后的文本。
    static func apply(_ text: String, rules: [CorrectionRule]) -> String {
        guard !text.isEmpty else { return text }
        let active = rules
            .map { $0.trimmed() }
            .filter { !$0.match.isEmpty && !$0.replacement.isEmpty }
            .sorted { $0.match.count > $1.match.count }
        var result = text
        for rule in active {
            result = replace(rule, in: result)
        }
        return result
    }

    // MARK: - 私有

    private static func replace(_ rule: CorrectionRule, in text: String) -> String {
        if containsCJK(rule.match) {
            return text.replacingOccurrences(of: rule.match, with: rule.replacement)
        }
        // 拉丁词：自定义词边界 + 大小写不敏感。
        // 不能用 \b——ICU 把 CJK 表意字也算词字符，「那个cloud code」里 \b 不成立，
        // 而纯中文夹英文正是主要使用场景。这里只把 ASCII 字母数字视为词字符：
        // 前/后是 ASCII 字母数字才算词内（保护 cloudy），是中文/空格/标点则算边界。
        let escaped = NSRegularExpression.escapedPattern(for: rule.match)
            .replacingOccurrences(of: " ", with: "\\s+")  // 口语识别空格数不稳定，宽松匹配
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])",
            options: [.caseInsensitive]
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range,
            withTemplate: rule.replacement.escapedRegexTemplate
        )
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }
}

private extension CorrectionRule {
    func trimmed() -> CorrectionRule {
        var r = self
        r.match = match.trimmingCharacters(in: .whitespaces)
        r.replacement = replacement.trimmingCharacters(in: .whitespaces)
        return r
    }
}

private extension String {
    /// NSRegularExpression 的替换模板里 `$` 有特殊含义，需转义。
    var escapedRegexTemplate: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "$$")
    }
}
