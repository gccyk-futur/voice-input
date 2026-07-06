import Foundation

/// OpenAI 兼容流式引擎（/chat/completions，SSE 返回 choices[0].delta.content）。
/// 适用于 OpenAI / DeepSeek / 自定义 OpenAI 兼容端点。
final class OpenAICompatibleEngine: LLMEngine {
    enum Kind { case openai, deepseek, custom }

    let id: String
    let displayName: String

    private let baseUrl: String
    private let apiKey: String
    private let model: String
    private let temperature: Double
    private let client = StreamingClient()

    init(baseUrl: String, apiKey: String, model: String, temperature: Double, kind: Kind) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        switch kind {
        case .openai: id = "openai"; displayName = "OpenAI"
        case .deepseek: id = "deepseek"; displayName = "DeepSeek"
        case .custom: id = "custom"; displayName = "Custom"
        }
    }

    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error> {
        var comps = URLComponents(string: baseUrl)
        comps?.path = "/chat/completions"
        var req = URLRequest(url: comps?.url ?? URL(string: baseUrl)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userTemplate]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return client.stream(request: req) { data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { return nil }
            return content
        }
    }
}
