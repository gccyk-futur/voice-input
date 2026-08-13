import Foundation
@preconcurrency import AVFAudio

/// 讯飞语音听写（流式版）引擎（WebSocket，每次会话一条连接）。
///
/// 握手用 hmac-sha256 签名 URL（XunfeiAuth）；首帧携带 common/business，
/// 音频以 base64 JSON 文本帧上传（status 0/1），结束发 status 2；
/// 结果经 XunfeiResultAssembler 组装（支持 wpgs 动态修正）。
/// 会话上限 60s、10s 无数据服务端断开——语音输入为短会话场景，天然适配。
final class XunfeiASREngine: NSObject, ASREngine, @unchecked Sendable {
    let id = "xunfei"
    let displayName = VoiceKitLocalization.string("讯飞听写")
    let requiresForeground = false

    var onFailure: (@Sendable (Error) -> Void)? {
        get { stateLock.withLock { _onFailure } }
        set { stateLock.withLock { _onFailure = newValue } }
    }
    private var _onFailure: (@Sendable (Error) -> Void)?

    /// 连接状态变化回调（连接中…/已连接/已断开），供状态栏指示灯展示。
    var onConnectionChange: (@Sendable (Bool, String) -> Void)? {
        get { stateLock.withLock { _onConnectionChange } }
        set { stateLock.withLock { _onConnectionChange = newValue } }
    }
    private var _onConnectionChange: (@Sendable (Bool, String) -> Void)?

    /// 触发连接状态回调（锁外执行）
    private func notifyConnectionChange(_ connected: Bool, _ status: String) {
        let cb = stateLock.withLock { _onConnectionChange }
        cb?(connected, status)
    }

    // MARK: - 状态锁 — 保护所有跨线程访问的 mutable 状态

    private let stateLock = NSLock()

    private let appId: String
    private let apiKey: String
    private let apiSecret: String
    private let dynamicCorrection: Bool
    /// 讯飞一条连接对应一次听写会话，服务端上限 60s。
    let maxSessionDuration: TimeInterval? = 60
    private let autoStopEnabled: Bool
    private let autoStopTimeout: TimeInterval

    private let capture = AudioCapture()
    /// 每会话新建 session：讯飞一条连接对应一次听写会话（≤60s）。
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "com.voicemate.xunfei.send")

    // 以下字段均受 stateLock 保护
    private var _assembler = XunfeiResultAssembler()
    private var _stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var _connectCont: CheckedContinuation<Void, Error>?
    private var _connectTimeoutTask: Task<Void, Never>?
    private var _stopRequested = false
    private var _sessionActive = false
    private var _isConnected = false
    private var _firstFrameSent = false
    /// 发出结束帧后等待服务端最终结果的上限。
    /// 原为 3s，实测网络延迟偏高时会撞满超时，导致最后一两句被丢弃；
    /// 等待造成的只是延迟，超时造成的是丢字，两害相权取其轻。
    static let finalResultTimeoutNs: UInt64 = 8_000_000_000
    private var _serverDone = false
    private var _language: String = "zh_cn"
    private var _audioGate: AudioPreRollSendGate?
    private var _onPartial: (@Sendable (String) -> Void)?
    private var _onAudioLevel: (@Sendable (Float) -> Void)?
    private var _onAutoStop: (@Sendable () -> Bool)?
    private var _receiveTask: Task<Void, Never>?
    /// 启动期（_sessionActive 尚未置位）发生的致命错误：由 start() 抛出，
    /// 走启动失败的单一错误通道，避免 onFailure 与 start 抛错双重上报。
    private var _startupError: Error?

    init(appId: String, apiKey: String, apiSecret: String,
         dynamicCorrection: Bool = true,
         autoStopEnabled: Bool = true, autoStopTimeout: TimeInterval = 3.5) {
        self.appId = appId
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.dynamicCorrection = dynamicCorrection
        self.autoStopEnabled = autoStopEnabled
        self.autoStopTimeout = autoStopTimeout
        super.init()
    }

    deinit {
        let task: URLSessionWebSocketTask? = stateLock.withLock {
            _receiveTask?.cancel()
            _connectTimeoutTask?.cancel()
            _connectCont?.resume(throwing: XunfeiASRError.notConnected)
            _connectCont = nil
            _stopWaiters.forEach { $0.resume() }
            _stopWaiters.removeAll()
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        task?.cancel()
        session?.invalidateAndCancel()
    }

    // MARK: - ASREngine

    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws {
        try capture.ensureInputAvailable()

        // 讯飞听写仅支持中/英（小语种需另行授权与独立域名），其余语言明确报错由上层提示。
        guard let lang = Self.languageCode(for: locale) else {
            throw ASRError.speechNotAvailable(locale: locale.identifier)
        }

        let gate = AudioPreRollSendGate(sendQueue: sendQueue) { [weak self] data in
            self?.sendAudioData(data)
        }
        stateLock.withLock {
            _assembler.reset()
            _stopRequested = false
            _sessionActive = false
            _firstFrameSent = false
            _serverDone = false
            _startupError = nil
            _language = lang
            _audioGate = gate
            _onPartial = onPartial
            _onAudioLevel = onAudioLevel
            _onAutoStop = onAutoStop
        }
        Log.info("[Xunfei] 音频预缓冲已创建，language=\(lang)")

        do {
            try await startAudioCapture(gate: gate)
            try await connect(timeout: 5)

            // 启动期（连接建立前）发生的致命错误（预缓冲溢出、音频路由中断等）
            // 已由 failSession 记录，这里抛出，走启动失败的单一错误通道。
            if let startupError = stateLock.withLock({ _startupError }) {
                throw startupError
            }

            let stopWasRequested = stateLock.withLock {
                _sessionActive = true
                return _stopRequested
            }
            if stopWasRequested {
                await finishAndWait()
                throw XunfeiASRError.cancelled
            }

            let bufferedBytes = gate.bufferedByteCount
            Log.info("[Xunfei] 音频预缓冲开始排空，bytes=\(bufferedBytes)")
            guard await gate.serverReady() else {
                throw XunfeiASRError.cancelled
            }
            Log.info("[Xunfei] 音频预缓冲已排空，进入实时发送")
        } catch {
            capture.stop()
            gate.discard()
            stateLock.withLock {
                if _audioGate === gate { _audioGate = nil }
            }
            teardownConnection()
            throw error
        }
    }

    func stop() async throws -> String {
        capture.stop()
        stateLock.withLock { _audioGate?.discard(); _audioGate = nil }

        let active = stateLock.withLock {
            _stopRequested = true
            return _sessionActive
        }
        guard active else {
            teardownConnection()
            return stateLock.withLock { _assembler.text }
        }
        await finishAndWait()
        return stateLock.withLock { _assembler.text }
    }

    static func languageCode(for locale: Locale) -> String? {
        switch locale.language.languageCode?.identifier {
        case "zh": return "zh_cn"
        case "en": return "en_us"
        default: return nil
        }
    }

    // MARK: - 连接

    private func connect(timeout: TimeInterval) async throws {
        guard let url = XunfeiAuth.signedURL(
            host: "iat-api.xfyun.cn", path: "/v2/iat",
            apiKey: apiKey, apiSecret: apiSecret
        ) else { throw XunfeiASRError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        stateLock.withLock {
            self.session?.invalidateAndCancel()
            self.session = session
            self.webSocketTask = task
            self._isConnected = false
        }
        task.resume()
        notifyConnectionChange(false, VoiceKitLocalization.string("连接中…"))
        Log.info("[Xunfei] 正在连接 WebSocket…")

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            var cont: CheckedContinuation<Void, Error>?
            self.stateLock.withLock {
                cont = self._connectCont
                self._connectCont = nil
            }
            cont?.resume(throwing: XunfeiASRError.connectTimeout)
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                stateLock.withLock {
                    if self._isConnected {
                        cont.resume()
                        timeoutTask.cancel()
                    } else {
                        self._connectCont = cont
                        self._connectTimeoutTask = timeoutTask
                    }
                }
            }
        } catch {
            stateLock.withLock { self._connectTimeoutTask = nil }
            throw error
        }
        stateLock.withLock { _connectTimeoutTask = nil }

        let receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            while true {
                if Task.isCancelled { break }
                let msg: URLSessionWebSocketTask.Message
                do {
                    msg = try await task.receive()
                } catch {
                    Log.error("[Xunfei] 接收循环断开: \(error)")
                    break
                }
                if case .string(let jsonText) = msg {
                    self.handle(jsonText: jsonText)
                }
            }
            self.receiveLoopEnded()
        }
        stateLock.withLock { _receiveTask = receiveTask }
    }

    /// 音频以 base64 JSON 文本帧上传；首帧（status 0）携带 common/business。
    private func sendAudioData(_ bytes: Data) {
        let (task, isFirst, lang, wpgs) = stateLock.withLock { () -> (URLSessionWebSocketTask?, Bool, String, Bool) in
            let first = !_firstFrameSent
            return (webSocketTask, first, _language, dynamicCorrection && _language == "zh_cn")
        }
        // 首帧标志必须在确认 task 存在后才消耗：否则 teardown 恰好发生在排空窗口时，
        // 含 common/business 的首帧没发出去但标志已置位，后续帧全是 status 1，服务端报错。
        guard let task else { return }
        if isFirst {
            stateLock.withLock { _firstFrameSent = true }
        }

        var payload: [String: Any] = [
            "data": [
                "status": isFirst ? 0 : 1,
                "format": "audio/L16;rate=16000",
                "encoding": "raw",
                "audio": bytes.base64EncodedString()
            ] as [String: Any]
        ]
        if isFirst {
            var business: [String: Any] = [
                "language": lang,
                "domain": "iat",
                "accent": "mandarin",
                "ptt": 1
            ]
            if wpgs { business["dwa"] = "wpgs" }
            payload["common"] = ["app_id": appId]
            payload["business"] = business
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// 发送 status 2 结束标识，等待服务端最终结果（status 2）或 3s 超时，然后关闭连接。
    private func finishAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let (task, alreadyDone) = stateLock.withLock { () -> (URLSessionWebSocketTask?, Bool) in
                _stopWaiters.append(cont)
                if _serverDone { return (webSocketTask, true) }
                return (webSocketTask, false)
            }
            if alreadyDone {
                resolveStopWaiters()
                return
            }
            guard let task else {
                resolveStopWaiters()
                return
            }
            Task { [weak self] in
                let end = "{\"data\":{\"status\":2}}"
                try? await task.send(.string(end))
                Log.info("[Xunfei] status=2 sent")
                try? await Task.sleep(nanoseconds: Self.finalResultTimeoutNs)
                if let self, self.stateLock.withLock({ !self._serverDone }) {
                    Log.error("[Xunfei] 等待服务端最终结果超时（8s），尾部文字可能不完整")
                }
                self?.resolveStopWaiters()
            }
        }
        // 讯飞建议以 1000 正常关闭
        stateLock.withLock { webSocketTask }?.cancel(with: .normalClosure, reason: nil)
        teardownConnection()
    }

    private func resolveStopWaiters() {
        let waiters = stateLock.withLock {
            let w = _stopWaiters
            _stopWaiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume() }
    }

    private func teardownConnection() {
        let (wsTask, urlSession, receiveTask) = stateLock.withLock { () -> (URLSessionWebSocketTask?, URLSession?, Task<Void, Never>?) in
            let t = webSocketTask
            webSocketTask = nil
            let s = session
            session = nil
            let r = _receiveTask
            _receiveTask = nil
            _isConnected = false
            _sessionActive = false
            return (t, s, r)
        }
        receiveTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        // 本地主动取消不一定触发 didClose，这里兜底一次断开状态
        notifyConnectionChange(false, VoiceKitLocalization.string("已断开"))
    }

    // MARK: - 音频

    private func startAudioCapture(gate: AudioPreRollSendGate) async throws {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let silence: SilenceConfig? = autoStopEnabled
            ? SilenceConfig(timeout: autoStopTimeout, gracePeriod: 1.0)
            : nil
        try capture.start(
            targetFormat: targetFormat,
            // 讯飞建议 40ms/1280B 一帧
            bufferSize: 640,
            silence: silence,
            onLevel: { [weak self] level in
                var cb: (@Sendable (Float) -> Void)?
                self?.stateLock.withLock { cb = self?._onAudioLevel }
                cb?(level)
            },
            onAutoStop: { [weak self] in
                var cb: (@Sendable () -> Bool)?
                self?.stateLock.withLock { cb = self?._onAutoStop }
                return cb?() ?? false
            },
            onInterruption: { [weak self] error in self?.failSession(error) },
            onBuffer: { [weak self] out in
                guard let self else { return }
                let len = Int(out.frameLength)
                guard len > 0, let ch = out.int16ChannelData?.pointee else { return }
                let bytes = Data(bytes: ch, count: len * 2)
                if case .overflow = gate.append(bytes) {
                    Log.error("[Xunfei] 音频预缓冲已满，终止当前会话")
                    self.failSession(XunfeiASRError.audioPreRollOverflow)
                }
            }
        )
        Log.info("[Xunfei] 音频引擎启动，等待连接")
    }

    /// 录音中发生不可恢复错误：停采集、解开等待者、通知上层。best-effort，不抛错。
    /// 启动期（_sessionActive 未置位）不触发 onFailure——start() 尚未返回，
    /// 错误记入 _startupError 由 start() 抛出，避免与 start 的错误通道双重上报。
    private func failSession(_ error: Error) {
        capture.stop()
        let (waiters, failureCB, wasActive) = stateLock.withLock { () -> ([CheckedContinuation<Void, Never>], (@Sendable (Error) -> Void)?, Bool) in
            let active = _sessionActive
            if !active {
                if _startupError == nil { _startupError = error }
                _audioGate?.discard()
                _audioGate = nil
            }
            _sessionActive = false
            let w = _stopWaiters
            _stopWaiters.removeAll()
            let cb = _onFailure
            return (w, cb, active)
        }
        guard wasActive else { return }
        waiters.forEach { $0.resume() }
        failureCB?(error)
    }

    // MARK: - 事件处理

    private func handle(jsonText: String) {
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let code = json["code"] as? Int ?? 0
        if code != 0 {
            let message = json["message"] as? String ?? "\(code)"
            Log.error("[Xunfei] 服务端错误: \(code) - \(message)")
            failSession(XunfeiASRError.serverError(code: code, message: message))
            return
        }

        guard let dataObj = json["data"] as? [String: Any] else { return }
        let status = dataObj["status"] as? Int ?? 1

        if let result = dataObj["result"] as? [String: Any] {
            let sn = result["sn"] as? Int ?? 0
            let pgs = result["pgs"] as? String
            let rg = result["rg"] as? [Int]
            var fragment = ""
            if let ws = result["ws"] as? [[String: Any]] {
                for w in ws {
                    if let cw = w["cw"] as? [[String: Any]] {
                        for c in cw {
                            fragment += c["w"] as? String ?? ""
                        }
                    }
                }
            }
            var display = ""
            stateLock.withLock {
                _assembler.apply(sn: sn, fragment: fragment, pgs: pgs, rg: rg)
                display = _assembler.text
                let cb = _onPartial
                cb?(display)
            }
        }

        if status == 2 {
            // 服务端结果全部返回
            stateLock.withLock { _serverDone = true }
            resolveStopWaiters()
        }
    }

    /// 接收循环结束：正常收尾（stop 流程）不报错；录音中意外断开时，
    /// 若已有识别文本（如讯飞 60s 会话上限被服务端强制断开），改走自动停止
    /// 通道让上层按正常 finalize 保留文字；无文本才按失败上报。
    private func receiveLoopEnded() {
        let (unexpected, serverDone, failureCB, autoStopCB, text) = stateLock.withLock {
            () -> (Bool, Bool, (@Sendable (Error) -> Void)?, (@Sendable () -> Bool)?, String) in
            let unexpected = _sessionActive && !_stopRequested && !_serverDone
            return (unexpected, _serverDone, _onFailure, _onAutoStop, _assembler.text)
        }
        // 只有「服务端已给出最终结果」或「意外断开」才解除 stop 等待。
        // 正常收尾时服务端收到 status=2 后随即关闭连接、接收循环跟着结束；
        // 若在此无条件解除，就短路了 finishAndWait 特意留出的 3 秒宽限，
        // 尚未到达的最终结果——通常正是最后一两句——会被直接丢弃。
        if serverDone || unexpected {
            resolveStopWaiters()
        } else {
            Log.info("[Xunfei] 接收循环已结束但服务端最终结果未到，保留等待宽限")
        }
        guard unexpected else { return }
        capture.stop()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let autoStopCB, autoStopCB() {
            Log.info("[Xunfei] 连接意外断开但已有识别文本，转正常结束流程")
            // 连接已死：直接 teardown，stop() 会走「非活跃」分支立即返回已识别文本，
            // 不再向已断开的连接发 status 2 空等 3s。
            teardownConnection()
            return
        }
        Log.error("[Xunfei] 录音中连接意外断开")
        failureCB?(XunfeiASRError.notConnected)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension XunfeiASREngine: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let isCurrent = stateLock.withLock {
            guard self.webSocketTask === webSocketTask else { return false }
            _isConnected = true
            return true
        }
        guard isCurrent else { return }
        Log.info("[Xunfei] WebSocket 已连接")
        notifyConnectionChange(true, VoiceKitLocalization.string("已连接"))
        var cont: CheckedContinuation<Void, Error>?
        stateLock.withLock {
            cont = _connectCont
            _connectCont = nil
            _connectTimeoutTask?.cancel()
            _connectTimeoutTask = nil
        }
        cont?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let isCurrent = stateLock.withLock {
            guard self.webSocketTask === webSocketTask else { return false }
            _isConnected = false
            return true
        }
        guard isCurrent else { return }
        Log.info("[Xunfei] WebSocket 关闭 code=\(closeCode.rawValue)")
        notifyConnectionChange(false, VoiceKitLocalization.string("已断开"))
        var cont: CheckedContinuation<Void, Error>?
        stateLock.withLock {
            cont = _connectCont
            _connectCont = nil
        }
        cont?.resume(throwing: XunfeiASRError.notConnected)
    }
}

enum XunfeiASRError: LocalizedError {
    case invalidURL
    case notConnected
    case cancelled
    case connectTimeout
    case audioPreRollOverflow
    case serverError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return VoiceKitLocalization.string("讯飞听写 WebSocket URL 无效")
        case .notConnected: return VoiceKitLocalization.string("讯飞听写未连接")
        case .cancelled: return VoiceKitLocalization.string("讯飞听写任务已取消")
        case .connectTimeout: return VoiceKitLocalization.string("连接讯飞听写超时，请检查网络后重试")
        case .audioPreRollOverflow: return VoiceKitLocalization.string("讯飞听写启动较慢，请重试")
        case .serverError(let code, let message):
            return VoiceKitLocalization.format("讯飞听写失败（%d）：%@", code, message)
        }
    }
}
