import Foundation

/// 润色引擎协议：返回逐 token 的异步流。
protocol LLMEngine: AnyObject {
    /// 引擎标识："ollama" | "openai" | "deepseek" | ...
    var id: String { get }
    var displayName: String { get }

    /// 润色 text，逐段返回（token 增量）。
    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error>
}
