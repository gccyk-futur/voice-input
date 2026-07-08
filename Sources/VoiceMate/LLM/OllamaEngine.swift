import Foundation

/// 本地 Ollama 润色引擎（/api/chat 流式，逐字返回 message.content）。
final class OllamaEngine: LLMEngine {
    let id = "ollama"
    let displayName = "Ollama"

    private let baseUrl: String
    private let model: String
    private let temperature: Double
    private let numPredict: Int
    private let client = StreamingClient()

    init(config: LLMOllamaConfig) {
        self.baseUrl = config.baseUrl
        self.model = config.model
        self.temperature = config.temperature
        self.numPredict = config.numPredict
    }

    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error> {
        var comps = URLComponents(string: baseUrl)
        comps?.path = "/api/chat"
        var req = URLRequest(url: comps?.url ?? URL(string: baseUrl)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "options": ["temperature": temperature, "num_predict": numPredict],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userTemplate]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return client.stream(request: req) { data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return content
        }
    }

    func checkConnectivity() async -> Bool {
        var comps = URLComponents(string: baseUrl)
        comps?.path = "/api/tags"
        guard let url = comps?.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
