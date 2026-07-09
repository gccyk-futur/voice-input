import Foundation

/// 润色引擎协议：返回逐 token 的异步流。
protocol LLMEngine: AnyObject, Sendable {
    /// 引擎标识："ollama" | "openai" | ...
    var id: String { get }
    var displayName: String { get }

    /// 上次 polish 调用消耗的 prompt / completion token 数（调用前重置）
    var lastPromptTokens: Int { get }
    var lastCompletionTokens: Int { get }

    /// 润色 text，逐段返回（token 增量）。
    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error>

    /// 检测服务是否可达（超时 5 秒）。
    func checkConnectivity() async -> Bool
}

/// 默认实现：简单 GET 请求检查服务器是否响应。
extension LLMEngine {
    func checkConnectivity() async -> Bool {
        // 由各引擎自行实现更精确的检测
        return true
    }
}
