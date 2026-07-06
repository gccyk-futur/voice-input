import Foundation

/// Claude（Anthropic Messages API）流式润色引擎，复用通用 StreamingClient。
/// 注意：Anthropic 原生接口与 OpenAI 格式不同（/messages + x-api-key + anthropic-version）。
final class ClaudeEngine: LLMEngine {
    let id = "claude"
    let displayName = "Claude"

    private let baseUrl: String
    private let apiKey: String
    private let model: String
    private let temperature: Double
    private let client = StreamingClient()

    init(baseUrl: String, apiKey: String, model: String, temperature: Double) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
    }

    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error> {
        let url = URL(string: baseUrl)!.appendingPathComponent("messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": temperature,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": userTemplate]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return client.stream(request: req) { data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "content_block_delta",
                  let delta = obj["delta"] as? [String: Any],
                  let text = delta["text"] as? String else { return nil }
            return text
        }
    }
}
