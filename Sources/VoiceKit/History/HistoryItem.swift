import Foundation

struct HistoryItem: Codable, Identifiable {
    var id: String
    var timestamp: String
    var asrResult: String
    var llmResult: String?
    var engine: String
    var llmEngine: String?
    var favorite: Bool
    /// 本次会话的语音留档文件名（AudioLibrary 目录内）；nil 表示无留档。
    /// 可选字段：旧版 history.json 无此 key 时解码为 nil，天然向后兼容。
    var audioFile: String?
    /// 留档时长（秒）。
    var audioDuration: Double?
    /// 词汇纠正前的原始识别文本；仅在纠正改动了文本时非 nil（历史里可对照查看）。
    var asrRaw: String?

    init(asrResult: String, llmResult: String?, engine: String, llmEngine: String?,
         id: String = UUID().uuidString,
         audioFile: String? = nil, audioDuration: Double? = nil, asrRaw: String? = nil) {
        self.id = id
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.asrResult = asrResult
        self.llmResult = llmResult
        self.engine = engine
        self.llmEngine = llmEngine
        self.favorite = false
        self.audioFile = audioFile
        self.audioDuration = audioDuration
        self.asrRaw = asrRaw
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
