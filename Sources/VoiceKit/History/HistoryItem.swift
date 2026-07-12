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
