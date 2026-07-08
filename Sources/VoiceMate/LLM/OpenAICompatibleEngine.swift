import Foundation

/// OpenAI 兼容流式引擎（/chat/completions，SSE 返回 choices[0].delta.content）。
/// 适用于 OpenAI / DeepSeek / 自定义 OpenAI 兼容端点。
final class OpenAICompatibleEngine: LLMEngine, @unchecked Sendable {
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
        // 在 baseUrl 之后追加路径段，避免覆盖 baseUrl 原有的 /v1 前缀。
        let base = URL(string: baseUrl) ?? URL(string: "https://api.openai.com/v1")!
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
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

    func checkConnectivity() async -> Bool {
        let base = URL(string: baseUrl) ?? URL(string: "https://api.openai.com/v1")!
        let url = base.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        // 能收到 HTTP 响应（即使 401/403/404）说明服务器可达
        return http.statusCode > 0
    }
}
