import Foundation

/// 连接测试结果：成功，或失败（携带服务商/系统返回的原始信息，不转译）。
enum ASRConnTestResult: Equatable {
    case ok
    case failed(detail: String)
}

/// 云端引擎「测试连接」：只做轻量 WebSocket 握手，不用麦克风、不发送任何音频。
/// URL 构造与鉴权方式和各引擎正式连接保持一致；失败时把原始信息透传给专业用户，
/// 由其对照服务商官方文档排查，VoiceKit 不做二次转译。
enum ASRConnectionTester {

    static func testAliyun(_ cfg: ASRAliyunConfig) async -> ASRConnTestResult {
        let apiKey = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceId = cfg.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = cfg.region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !workspaceId.isEmpty, !region.isEmpty else {
            return .failed(detail: "API Key / Workspace ID / Region empty")
        }
        guard let url = URL(string: "wss://\(workspaceId).\(region).maas.aliyuncs.com/api-ws/v1/inference") else {
            return .failed(detail: "invalid WebSocket URL: wss://\(workspaceId).\(region).maas.aliyuncs.com/api-ws/v1/inference")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        switch await ConnProbe().run(req, waitFirstMessage: false) {
        case .opened, .firstMessage: return .ok
        case .failed(let detail): return .failed(detail: detail)
        }
    }

    static func testXunfei(_ cfg: ASRXunfeiConfig) async -> ASRConnTestResult {
        let apiKey = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiSecret = cfg.apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            return .failed(detail: "API Key / API Secret empty")
        }
        guard let url = XunfeiAuth.signedURL(host: "iat-api.xfyun.cn", path: "/v2/iat",
                                             apiKey: apiKey, apiSecret: apiSecret) else {
            return .failed(detail: "signed URL construction failed")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        switch await ConnProbe().run(req, waitFirstMessage: true) {
        case .opened:
            return .failed(detail: "connected but no response frame received")
        case .firstMessage(let text):
            // 讯飞首帧 code 字段为 0 才算鉴权通过；非 0 时把原始帧透传给用户
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["code"] as? Int, code == 0 {
                return .ok
            }
            return .failed(detail: text)
        case .failed(let detail):
            return .failed(detail: detail)
        }
    }

    static func testDeepgram(_ cfg: ASRDeepgramConfig) async -> ASRConnTestResult {
        let apiKey = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return .failed(detail: "API Key empty") }
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = "api.deepgram.com"
        comps.path = "/v1/listen"
        comps.queryItems = [URLQueryItem(name: "model", value: cfg.model)]
        guard let url = comps.url else { return .failed(detail: "invalid URL") }
        var req = URLRequest(url: url)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        // 连接成功后 Deepgram 会立刻推 Metadata 帧；凭据无效则被立即关闭，关闭原因即原始信息
        switch await ConnProbe().run(req, waitFirstMessage: true) {
        case .firstMessage: return .ok
        case .opened: return .failed(detail: "connected but no response frame received")
        case .failed(let detail): return .failed(detail: detail)
        }
    }
}

/// 一次性 WebSocket 探针：等握手成功（可选再等首帧），失败原因原样带回。
private final class ConnProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    private struct RawFailure: Error {
        let detail: String
    }

    enum Outcome {
        case opened
        case firstMessage(String)
        case failed(String)
    }

    private let lock = NSLock()
    private var openCont: CheckedContinuation<Void, Error>?
    private var closedDetail: String?

    func run(_ request: URLRequest, waitFirstMessage: Bool) async -> Outcome {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // 1. 握手：didOpen / didCloseWith / didCompleteWithError 三选一，8s 超时
        do {
            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { return }
                var cont: CheckedContinuation<Void, Error>?
                self.lock.withLock { cont = self.openCont; self.openCont = nil }
                cont?.resume(throwing: RawFailure(detail: "connect timeout (8s)"))
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.withLock { self.openCont = cont }
            }
            watchdog.cancel()
        } catch let e as RawFailure {
            return .failed(e.detail)
        } catch {
            return .failed(Self.describe(error, closedDetail: lock.withLock { closedDetail }))
        }

        guard waitFirstMessage else { return .opened }

        // 2. 首帧：receive 抛错或超时都按原始信息失败
        do {
            let msg = try await Self.withTimeout(seconds: 8) {
                try await task.receive()
            }
            switch msg {
            case .string(let text): return .firstMessage(text)
            case .data: return .firstMessage("<binary frame>")
            @unknown default: return .firstMessage("<unknown frame>")
            }
        } catch {
            return .failed(Self.describe(error, closedDetail: lock.withLock { closedDetail }))
        }
    }

    /// 错误描述：优先使用服务端关闭原因（含 close code / reason），其次系统错误原文。
    private static func describe(_ error: Error, closedDetail: String?) -> String {
        if let closedDetail, !closedDetail.isEmpty { return closedDetail }
        return "\(error)"
    }

    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RawFailure(detail: "response wait timeout (\(Int(seconds))s)")
            }
            guard let first = try await group.next() else {
                throw RawFailure(detail: "timeout")
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        var cont: CheckedContinuation<Void, Error>?
        lock.withLock { cont = openCont; openCont = nil }
        cont?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let detail = reasonText.isEmpty
            ? "WebSocket closed, code=\(closeCode.rawValue)"
            : "WebSocket closed, code=\(closeCode.rawValue), reason=\(reasonText)"
        var cont: CheckedContinuation<Void, Error>?
        lock.withLock {
            closedDetail = detail
            cont = openCont
            openCont = nil
        }
        cont?.resume(throwing: RawFailure(detail: detail))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        var cont: CheckedContinuation<Void, Error>?
        lock.withLock { cont = openCont; openCont = nil }
        cont?.resume(throwing: RawFailure(detail: "\(error)"))
    }
}
