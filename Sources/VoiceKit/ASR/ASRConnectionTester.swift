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
        let appId = cfg.appId.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiSecret = cfg.apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appId.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else {
            return .failed(detail: "APP ID / API Key / API Secret empty")
        }
        guard let url = XunfeiAuth.signedURL(host: "iat-api.xfyun.cn", path: "/v2/iat",
                                             apiKey: apiKey, apiSecret: apiSecret) else {
            return .failed(detail: "signed URL construction failed")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        // 讯飞 IAT 是应答式协议：握手只校验签名 URL，服务端在收到首帧前不会推任何数据；
        // 且首帧（40ms 静音）没有可识别内容时也不会回帧——只发一帧干等，15s 后会被
        // 服务端以 "server read msg timeout" 关闭（实测确认）。因此模拟真实引擎的
        // 最小会话：首帧（status 0 + common/business）+ 若干静音帧 + 结束帧（status 2），
        // 服务端收到结束帧后立刻回最终结果（code==0 即鉴权/参数全部通过）。
        // 这同时覆盖了握手无法校验的 appId（签名不含 appId，错误 appId 只在响应帧里报）。
        let silence = Data(count: 1280).base64EncodedString() // 40ms @16kHz
        var frames: [String] = []
        let firstFrame: [String: Any] = [
            "common": ["app_id": appId],
            "business": ["language": "zh_cn", "domain": "iat", "accent": "mandarin", "ptt": 1],
            "data": ["status": 0, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": silence]
        ]
        frames.append(Self.jsonText(firstFrame))
        for _ in 0 ..< 10 {
            frames.append(Self.jsonText([
                "data": ["status": 1, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": silence]
            ]))
        }
        frames.append(Self.jsonText([
            "data": ["status": 2, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": ""]
        ]))
        switch await ConnProbe().run(req, framesToSend: frames) {
        case .opened:
            return .failed(detail: "connected but no response frame received")
        case .firstMessage(let text):
            // 讯飞响应帧 code 字段为 0 才算鉴权通过；非 0 时把原始帧透传给用户
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

    private static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
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
        // Deepgram 连接成功后不会主动推任何帧（实测：Metadata 只在流结束/超时关闭时才下发，
        // 空等会被 12s 无音频超时以 1011 关闭）。鉴权失败在 WebSocket 握手阶段即被 401 拒绝，
        // 因此握手成功即代表凭据有效，与阿里云同策略。
        switch await ConnProbe().run(req, waitFirstMessage: false) {
        case .opened, .firstMessage: return .ok
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

    /// - Parameters:
    ///   - waitFirstMessage: 握手成功后是否再等一帧服务端消息。
    ///   - framesToSend: 握手成功后按 40ms 间隔依次发送的文本帧（应答式协议如讯飞
    ///     需要发完整会话——首帧+数据帧+结束帧——才有响应）；非空时隐含 waitFirstMessage = true。
    func run(_ request: URLRequest, waitFirstMessage: Bool = false, framesToSend: [String] = []) async -> Outcome {
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

        for frame in framesToSend {
            do {
                try await task.send(.string(frame))
            } catch {
                return .failed(Self.describe(error, closedDetail: lock.withLock { closedDetail }))
            }
            if frame != framesToSend.last {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }

        guard waitFirstMessage || !framesToSend.isEmpty else { return .opened }

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
        if let raw = error as? RawFailure { return raw.detail }
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
