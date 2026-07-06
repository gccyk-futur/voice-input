import Foundation

/// 通用流式 HTTP 客户端：基于 URLSession.bytes(for:) 逐行读取 SSE/JSON 流，
/// 通过 extract 闭包从每行 JSON 中抽取文本增量。支撑 Ollama / OpenAI / DeepSeek / 自定义。
struct StreamingClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stream(request: URLRequest, extract: @escaping @Sendable (Data) -> String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if json == "[DONE]" { continue }
                        if let data = json.data(using: .utf8),
                           let text = extract(data) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
