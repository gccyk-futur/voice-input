import Foundation
@preconcurrency import AVFAudio

/// Deepgram 实时语音识别引擎（WebSocket，每次会话一条连接）。
///
/// 协议简单：参数走 URL query（model/language/encoding/interim_results 等），
/// 握手成功后直接发二进制 PCM；结果以 JSON 推送（is_final/speech_final 双层结束信号）；
/// 结束时发 {"type":"CloseStream"}，服务端 flush 最终结果后关闭连接。
/// 无 run-task 握手往返，连接打开即可发音频，配合 AudioPreRollSendGate 吸收握手延迟。
final class DeepgramASREngine: NSObject, ASREngine, @unchecked Sendable {
    let id = "deepgram"
    let displayName = "Deepgram"
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

    private let apiKey: String
    private let model: String
    private let autoStopEnabled: Bool
    private let autoStopTimeout: TimeInterval

    private let capture = AudioCapture()
    /// 每会话新建 session：避免跨会话复用连接（Deepgram 一条连接对应一次识别流）。
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "com.voicemate.deepgram.send")

    // 以下字段均受 stateLock 保护
    private var _finalText: String = ""
    private var _currentPartial: String = ""
    private var _stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var _connectCont: CheckedContinuation<Void, Error>?
    private var _connectTimeoutTask: Task<Void, Never>?
    private var _stopRequested = false
    private var _sessionActive = false
    private var _isConnected = false
    private var _audioGate: AudioPreRollSendGate?
    private var _onPartial: (@Sendable (String) -> Void)?
    private var _onAudioLevel: (@Sendable (Float) -> Void)?
    private var _onAutoStop: (@Sendable () -> Bool)?
    private var _receiveTask: Task<Void, Never>?
    /// 底层连接错误的原始描述（close code / receive 异常），报错时透传给用户，不做转译。
    private var _lastUnderlyingError: String?
    /// 启动期（_sessionActive 尚未置位）发生的致命错误：由 start() 抛出，
    /// 走启动失败的单一错误通道，避免 onFailure 与 start 抛错双重上报。
    private var _startupError: Error?

    init(apiKey: String, model: String = "nova-3",
         autoStopEnabled: Bool = true, autoStopTimeout: TimeInterval = 3.5) {
        self.apiKey = apiKey
        self.model = model
        self.autoStopEnabled = autoStopEnabled
        self.autoStopTimeout = autoStopTimeout
        super.init()
    }

    deinit {
        let task: URLSessionWebSocketTask? = stateLock.withLock {
            _receiveTask?.cancel()
            _connectTimeoutTask?.cancel()
            _connectCont?.resume(throwing: DeepgramASRError.notConnected)
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

        let gate = AudioPreRollSendGate(sendQueue: sendQueue) { [weak self] data in
            self?.sendAudioData(data)
        }
        stateLock.withLock {
            _finalText = ""
            _currentPartial = ""
            _stopRequested = false
            _sessionActive = false
            _lastUnderlyingError = nil
            _startupError = nil
            _audioGate = gate
            _onPartial = onPartial
            _onAudioLevel = onAudioLevel
            _onAutoStop = onAutoStop
        }
        Log.info("[Deepgram] 音频预缓冲已创建")

        do {
            try await startAudioCapture(gate: gate)
            try await connect(locale: locale, timeout: 5)

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
                throw DeepgramASRError.cancelled
            }

            let bufferedBytes = gate.bufferedByteCount
            Log.info("[Deepgram] 音频预缓冲开始排空，bytes=\(bufferedBytes)")
            guard await gate.serverReady() else {
                throw DeepgramASRError.cancelled
            }
            Log.info("[Deepgram] 音频预缓冲已排空，进入实时发送")
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
            return stateLock.withLock { _finalText }
        }
        await finishAndWait()
        return stateLock.withLock { _finalText }
    }

    // MARK: - 连接

    private func connect(locale: Locale, timeout: TimeInterval) async throws {
        guard let url = listenURL(locale: locale) else { throw DeepgramASRError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
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
        Log.info("[Deepgram] 正在连接 WebSocket…")

        // 等待握手（didOpen resume），带超时
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            var cont: CheckedContinuation<Void, Error>?
            self.stateLock.withLock {
                cont = self._connectCont
                self._connectCont = nil
            }
            cont?.resume(throwing: DeepgramASRError.connectTimeout)
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

        // 统一接收循环
        let receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            while true {
                if Task.isCancelled { break }
                let msg: URLSessionWebSocketTask.Message
                do {
                    msg = try await task.receive()
                } catch {
                    Log.error("[Deepgram] 接收循环断开: \(error)")
                    self.stateLock.withLock { self._lastUnderlyingError = "\(error)" }
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

    private func listenURL(locale: Locale) -> URL? {
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = "api.deepgram.com"
        comps.path = "/v1/listen"
        comps.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: languageCode(for: locale)),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "utterance_end_ms", value: "1000")
        ]
        return comps.url
    }

    private func languageCode(for locale: Locale) -> String {
        let id = locale.language.languageCode?.identifier ?? "zh"
        switch id {
        case "zh":
            // 简/繁分流：Deepgram 支持 zh-CN / zh-TW
            return locale.identifier.contains("Hant") || locale.identifier.contains("TW") || locale.identifier.contains("HK")
                ? "zh-TW" : "zh-CN"
        default:
            return id
        }
    }

    private func sendAudioData(_ bytes: Data) {
        let task = stateLock.withLock { webSocketTask }
        task?.send(.data(bytes)) { _ in }
    }

    /// 发送 CloseStream 并等待服务端关闭连接（flush 最终结果），3s 超时兜底。
    private func finishAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let task = stateLock.withLock {
                _stopWaiters.append(cont)
                return webSocketTask
            }
            guard let task else {
                resolveStopWaiters()
                return
            }
            Task { [weak self] in
                try? await task.send(.string("{\"type\":\"CloseStream\"}"))
                Log.info("[Deepgram] CloseStream sent")
                // 超时兜底：服务端未关闭也放行
                try? await Task.sleep(nanoseconds: 8_000_000_000)   // 见讯飞引擎中同一常量的说明：宁可多等，不可丢字
                self?.resolveStopWaiters()
            }
        }
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
            bufferSize: 1024,
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
                    Log.error("[Deepgram] 音频预缓冲已满，终止当前会话")
                    self.failSession(DeepgramASRError.audioPreRollOverflow)
                }
            }
        )
        Log.info("[Deepgram] 音频引擎启动，等待连接")
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
        let type = json["type"] as? String
        guard type == "Results" else { return } // Metadata / UtteranceEnd / SpeechStarted 等忽略

        guard let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first else { return }
        let transcript = first["transcript"] as? String ?? ""
        let isFinal = json["is_final"] as? Bool ?? false
        guard !transcript.isEmpty else { return }

        stateLock.withLock {
            if isFinal {
                _finalText += (_finalText.isEmpty ? "" : " ") + transcript
                _currentPartial = ""
            } else {
                _currentPartial = transcript
            }
            let display = _finalText + (_currentPartial.isEmpty ? "" : " " + _currentPartial)
            let cb = _onPartial
            cb?(display)
        }
    }

    /// 接收循环结束：正常收尾（stop 流程）不报错；录音中意外断开时，
    /// 若已有识别文本，改走自动停止通道让上层按正常 finalize 保留文字；
    /// 无文本才按失败上报（透传底层错误原文）。
    private func receiveLoopEnded() {
        let (unexpected, failureCB, autoStopCB, text, underlying) = stateLock.withLock {
            () -> (Bool, (@Sendable (Error) -> Void)?, (@Sendable () -> Bool)?, String, String?) in
            // stopRequested 表示用户主动结束，断开属于正常收尾
            let unexpected = _sessionActive && !_stopRequested
            let display = _finalText + (_currentPartial.isEmpty ? "" : " " + _currentPartial)
            return (unexpected, _onFailure, _onAutoStop, display, _lastUnderlyingError)
        }
        resolveStopWaiters()
        guard unexpected else { return }
        capture.stop()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let autoStopCB, autoStopCB() {
            Log.info("[Deepgram] 连接意外断开但已有识别文本，转正常结束流程")
            // 把最新 interim 并入最终结果；连接已死，直接 teardown，
            // stop() 走「非活跃」分支立即返回完整文本，不再向死连接发 CloseStream 空等 3s。
            stateLock.withLock {
                _finalText = text
                _currentPartial = ""
            }
            teardownConnection()
            return
        }
        Log.error("[Deepgram] 录音中连接意外断开")
        failureCB?(DeepgramASRError.connectionLost(underlying: underlying))
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DeepgramASREngine: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let isCurrent = stateLock.withLock {
            guard self.webSocketTask === webSocketTask else { return false }
            _isConnected = true
            return true
        }
        guard isCurrent else { return }
        Log.info("[Deepgram] WebSocket 已连接")
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
        Log.info("[Deepgram] WebSocket 关闭 code=\(closeCode.rawValue)")
        notifyConnectionChange(false, VoiceKitLocalization.string("已断开"))
        var cont: CheckedContinuation<Void, Error>?
        stateLock.withLock {
            _lastUnderlyingError = "WebSocket closed, code=\(closeCode.rawValue)"
            cont = _connectCont
            _connectCont = nil
        }
        cont?.resume(throwing: DeepgramASRError.connectionLost(underlying: "WebSocket closed, code=\(closeCode.rawValue)"))
    }
}

enum DeepgramASRError: LocalizedError {
    case invalidURL
    case notConnected
    case cancelled
    case connectTimeout
    case audioPreRollOverflow
    /// 连接丢失/被拒绝，带服务商或系统返回的原始信息（不转译，供专业用户对照官方文档排查）。
    case connectionLost(underlying: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return VoiceKitLocalization.string("Deepgram WebSocket URL 无效")
        case .notConnected: return VoiceKitLocalization.string("Deepgram 未连接")
        case .cancelled: return VoiceKitLocalization.string("Deepgram 任务已取消")
        case .connectTimeout: return VoiceKitLocalization.string("连接 Deepgram 超时，请检查网络后重试")
        case .audioPreRollOverflow: return VoiceKitLocalization.string("Deepgram 启动较慢，请重试")
        case .connectionLost(let underlying):
            if let underlying, !underlying.isEmpty {
                return VoiceKitLocalization.format("Deepgram 连接失败：%@", underlying)
            }
            return VoiceKitLocalization.string("Deepgram 未连接")
        }
    }
}
