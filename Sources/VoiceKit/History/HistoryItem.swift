import Foundation

struct HistoryItem: Codable, Identifiable {
    var id: String
    var timestamp: String
    var asrResult: String
    var llmResult: String?
    var engine: String
    var llmEngine: String?
    var favorite: Bool

    init(asrResult: String, llmResult: String?, engine: String, llmEngine: String?) {
        self.id = UUID().uuidString
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.asrResult = asrResult
        self.llmResult = llmResult
        self.engine = engine
        self.llmEngine = llmEngine
        self.favorite = false
    }
}

extension HistoryItem {
    /// 引擎 id → 面向用户的显示名（历史列表徽标、导出共用）。
    var engineDisplayName: String {
        switch engine {
        case "system", "system-legacy": return VoiceKitLocalization.string("系统听写")
        case "aliyun": return VoiceKitLocalization.string("阿里云")
        case "xunfei": return VoiceKitLocalization.string("讯飞")
        case "deepgram": return "Deepgram"
        default: return engine
        }
    }
}
