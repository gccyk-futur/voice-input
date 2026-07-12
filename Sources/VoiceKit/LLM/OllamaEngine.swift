import Foundation

/// 本地 Ollama 润色引擎（/api/chat 流式，逐字返回 message.content）。
final class OllamaEngine: LLMEngine, @unchecked Sendable {
    let id = "ollama"
    let displayName = "Ollama"

    private let baseUrl: String
    private let model: String
    private let temperature: Double
    private let numPredict: Int

    nonisolated(unsafe) private var _lastPromptTokens: Int = 0
    nonisolated(unsafe) private var _lastCompletionTokens: Int = 0
    var lastPromptTokens: Int { _lastPromptTokens }
    var lastCompletionTokens: Int { _lastCompletionTokens }

    init(config: LLMOllamaConfig) {
        self.baseUrl = config.baseUrl
        self.model = config.model
        self.temperature = config.temperature
        self.numPredict = config.numPredict
    }

    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error> {
        _lastPromptTokens = 0
        _lastCompletionTokens = 0
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
        let reqCapture = req
        let box = TokenBox()
        let boxCapture = box
        return AsyncThrowingStream { continuation in
            _ = Task { [self] in
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: reqCapture)
                    if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines.prefix(2) { errorBody += line }
                        throw NSError(domain: "LLM", code: httpResp.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode): \(errorBody.prefix(200))"])
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = obj["message"] as? [String: Any],
                           let content = message["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if obj["done"] as? Bool == true {
                            boxCapture.prompt = obj["prompt_eval_count"] as? Int ?? 0
                            boxCapture.completion = obj["eval_count"] as? Int ?? 0
                        }
                    }
                    _lastPromptTokens = boxCapture.prompt
                    _lastCompletionTokens = boxCapture.completion
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
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
