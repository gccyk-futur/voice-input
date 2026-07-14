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

    nonisolated(unsafe) private var _lastPromptTokens: Int = 0
    nonisolated(unsafe) private var _lastCompletionTokens: Int = 0
    var lastPromptTokens: Int { _lastPromptTokens }
    var lastCompletionTokens: Int { _lastCompletionTokens }

    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error> {
        _lastPromptTokens = 0
        _lastCompletionTokens = 0
        // 去重：如果 baseUrl 已经以 /chat/completions 结尾就不再追加
        var urlStr = baseUrl
        if urlStr.hasSuffix("/chat/completions") {
            urlStr = String(urlStr.dropLast("/chat/completions".count))
        }
#if APP_STORE
        guard let base = URL(string: urlStr) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "LLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "未配置有效的 API 地址"]))
            }
        }
#else
        let base = URL(string: urlStr) ?? URL(string: "https://api.openai.com/v1")!
#endif
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        print("[LLM-Engine] request url=\(req.url?.absoluteString ?? "?")")
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
        let reqCapture = req
        let box = TokenBox()
        let boxCapture = box
        return AsyncThrowingStream { continuation in
            _ = Task { [self] in
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: reqCapture)
                    if let httpResp = response as? HTTPURLResponse {
                        print("[LLM-Engine] HTTP \(httpResp.statusCode) \(httpResp.url?.absoluteString ?? "?")")
                        guard httpResp.statusCode == 200 else {
                            var errorBody = ""
                            for try await line in bytes.lines.prefix(2) { errorBody += line }
                            print("[LLM-Engine] HTTP error body: \(errorBody.prefix(300))")
                            throw NSError(domain: "LLM", code: httpResp.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode): \(errorBody.prefix(200))"])
                        }
                    }
                    var lineCount = 0
                    for try await line in bytes.lines {
                        lineCount += 1
                        if lineCount <= 3 {
                            print("[LLM-Engine] raw line[\(lineCount)]: \(line.prefix(200))")
                        }
                        guard line.hasPrefix("data:") else {
                            if !line.trimmingCharacters(in: .whitespaces).isEmpty && lineCount <= 5 {
                                print("[LLM-Engine] skip non-data line[\(lineCount)]: \(line.prefix(100))")
                            }
                            continue
                        }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if json == "[DONE]" { continue }
                        guard let data = json.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            if lineCount <= 5 { print("[LLM-Engine] json parse fail line[\(lineCount)]") }
                            continue
                        }
                        if let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            continuation.yield(content)
                        } else if lineCount <= 5 {
                            print("[LLM-Engine] no content in line[\(lineCount)] keys=\(obj.keys)")
                        }
                        if let usage = obj["usage"] as? [String: Any] {
                            boxCapture.prompt = usage["prompt_tokens"] as? Int ?? 0
                            boxCapture.completion = usage["completion_tokens"] as? Int ?? 0
                        }
                    }
                    // 在 finish() 之前赋值，确保 handleFinal 能读到
                    _lastPromptTokens = boxCapture.prompt
                    _lastCompletionTokens = boxCapture.completion
                    print("[LLM-Engine] stream done, \(lineCount) lines, tokens: prompt=\(_lastPromptTokens) completion=\(_lastCompletionTokens)")
                    continuation.finish()
                } catch {
                    print("[LLM-Engine] error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func checkConnectivity() async -> Bool {
        var urlStr = baseUrl
        if urlStr.hasSuffix("/chat/completions") {
            urlStr = String(urlStr.dropLast("/chat/completions".count))
        }
#if APP_STORE
        guard let base = URL(string: urlStr) else {
            print("[LLM-Engine] invalid base URL for connectivity check")
            return false
        }
#else
        let base = URL(string: urlStr) ?? URL(string: "https://api.openai.com/v1")!
#endif
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