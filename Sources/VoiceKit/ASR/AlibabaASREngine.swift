import Foundation
@preconcurrency import AVFAudio

/// 阿里云百炼 Fun-ASR 实时语音识别引擎（WebSocket 长连接）。
///
/// 连接常驻，每次 start/stop 只收发 run-task / finish-task，不复重连。
/// semantic_punctuation_enabled 自动加标点，结果用空格拼接而非换行。
///
/// 连接状态用 URLSessionWebSocketDelegate 的真实握手回调驱动（不再在 resume 后
/// 乐观置位）；start 前会 ensureConnected，未连接时主动建连并带超时兜底。
final class AlibabaASREngine: NSObject, ASREngine, @unchecked Sendable {
    let id = "aliyun"
    let displayName = "阿里云 Fun-ASR"
    let requiresForeground = false

    var onFailure: (@Sendable (Error) -> Void)? {
        get { stateLock.withLock { _onFailure } }
        set { stateLock.withLock { _onFailure = newValue } }
    }
    private var _onFailure: (@Sendable (Error) -> Void)?

    // MARK: - 状态锁 — 保护所有跨线程访问的 mutable 状态

    private let stateLock = NSLock()

    private let apiKey: String
    private let workspaceId: String
    private let region: String
    private let model: String
    private let semanticPunctuation: Bool
    private let speechNoiseThreshold: Double
    private let maxSentenceSilence: Int
    private let autoStopEnabled: Bool
    private let autoStopTimeout: TimeInterval
    private let autoStopThreshold: Float

    private let capture = AudioCapture()
    /// 常驻 URLSession：整个引擎生命周期复用，避免每次重连新建 session 导致连接/线程泄漏。
    /// delegate 为 self，必须在 super.init 之后创建，故用 IUO。
    private var session: URLSession!
    private var webSocketTask: URLSessionWebSocketTask?
    private var taskId: String = ""
    private let sendQueue = DispatchQueue(label: "com.voicemate.aliyun.send")

    // 以下字段均受 stateLock 保护
    private var _finalText: String = ""
    private var _currentPartial: String = ""
    private var _taskFinishedCont: CheckedContinuation<Void, Never>?
    private var _taskStartedCont: CheckedContinuation<Void, Error>?
    /// 等待握手完成的 continuation（ensureConnected 注册，didOpen/超时 resume）。
    private var _connectWait: (id: UUID, cont: CheckedContinuation<Void, Error>)?
    private var _isConnected = false
    /// 是否已有一次重连在排队（防止 didClose 与接收循环双触发）。
    private var _reconnectScheduled = false
    private var _onPartial: (@Sendable (String) -> Void)?
    private var _onAudioLevel: (@Sendable (Float) -> Void)?
    private var _onAutoStop: (@Sendable () -> Bool)?
    private var _receiveTask: Task<Void, Never>?
    /// 重连指数退避计数器（0=首次连接）
    private var _reconnectAttempt: Int = 0

    // 超时 Task 引用 — 用于取消
    private var _startedTimeoutTask: Task<Void, Never>?
    private var _stoppedTimeoutTask: Task<Void, Never>?
    private var _connectTimeoutTask: Task<Void, Never>?

    /// session 活跃标记：接收循环据此在 finish 后退出，而非触发重连。
    private var _sessionActive = false

    var wsConnected: Bool { stateLock.withLock { _isConnected } }

    init(apiKey: String, workspaceId: String, region: String, model: String,
         semanticPunctuation: Bool = true, speechNoiseThreshold: Double = 0, maxSentenceSilence: Int = 1300,
         autoStopEnabled: Bool = true, autoStopTimeout: TimeInterval = 3.5, autoStopThreshold: Float = 0.01) {
        self.apiKey = apiKey
        self.workspaceId = workspaceId
        self.region = region
        self.model = model
        self.semanticPunctuation = semanticPunctuation
        self.speechNoiseThreshold = speechNoiseThreshold
        self.maxSentenceSilence = maxSentenceSilence
        self.autoStopEnabled = autoStopEnabled
        self.autoStopTimeout = autoStopTimeout
        self.autoStopThreshold = autoStopThreshold
        super.init()
        // session 在整个引擎生命周期复用；delegate 为 self（必须在 super.init 之后）
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        connect()
    }

    deinit {
        stateLock.withLock {
            _receiveTask?.cancel()
            _startedTimeoutTask?.cancel()
            _stoppedTimeoutTask?.cancel()
            _connectTimeoutTask?.cancel()
            _taskStartedCont?.resume(throwing: AlibabaASRError.notConnected)
            _taskStartedCont = nil
            _taskFinishedCont?.resume()
            _taskFinishedCont = nil
            _connectWait?.cont.resume(throwing: AlibabaASRError.notConnected)
            _connectWait = nil
        }
        webSocketTask?.cancel()
        session?.invalidateAndCancel()
    }

    /// 重连最大退避时间（秒）
    private static let maxReconnectDelay: TimeInterval = 30

    // MARK: - 常驻连接

    private func connect() {
        guard let url = URL(string: "wss://\(workspaceId).\(region).maas.aliyuncs.com/api-ws/v1/inference") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        // 取消旧的接收循环和 WebSocket 任务，避免多个连接并存；session 复用不重建
        stateLock.withLock {
            _receiveTask?.cancel()
            _receiveTask = nil
            _reconnectScheduled = false
            // 注意：此时还不能置 _isConnected = true，需等 delegate didOpen 回调确认握手成功
        }
        webSocketTask?.cancel()
        webSocketTask = session.webSocketTask(with: req)
        webSocketTask?.resume()
        Log.info("[AlibabaASR] 正在连接 WebSocket…")

        // 握手看门狗：10s 内没收到 didOpen → 认为连接失败，安排重连。
        // 与 ensureConnected 的超时互不干扰（后者只让当次 start 快速失败返回）。
        // scheduleReconnect 内部以原子方式守卫 _reconnectScheduled，不会与
        // didClose / 接收循环的重连触发重复。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            let connected = self.stateLock.withLock { self._isConnected }
            if !connected {
                Log.info("[AlibabaASR] 握手超时，安排重连")
                self.scheduleReconnect()
            }
        }

        // 统一接收循环：处理所有服务端事件
        let task = Task.detached { [weak self] in
            guard let self else { return }
            while true {
                if Task.isCancelled { break }

                guard let ws = self.webSocketTask else { break }

                let msg: URLSessionWebSocketTask.Message
                do {
                    msg = try await ws.receive()
                } catch {
                    // 对端关闭、网络断开、超时等 → 退出循环，由下面决定是否重连
                    Log.error("[AlibabaASR] 接收循环断开: \(error)")
                    break
                }

                switch msg {
                case .string(let jsonText):
                    guard let data = jsonText.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let header = json["header"] as? [String: Any],
                          let event = header["event"] as? String else { continue }
                    self.handle(event: event, header: header, json: json)
                case .data: break
                @unknown default: break
                }
            }
            // 正常 finish 路径（session 结束且仍连接）不重连
            var active = false
            self.stateLock.withLock { active = self._sessionActive }
            if active {
                Log.info("[AlibabaASR] session 结束，不触发重连")
                return
            }
            guard !Task.isCancelled else { return }
            Log.error("[AlibabaASR] 连接异常断开，将重连")
            self.scheduleReconnect()
        }
        stateLock.withLock { _receiveTask = task }
    }

    /// 幂等地安排一次重连（指数退避 + jitter）。didClose 与接收循环都可能调用，
    /// 用 _reconnectScheduled 保证同一轮只重连一次。
    private func scheduleReconnect() {
        let delay: TimeInterval = stateLock.withLock {
            guard !_reconnectScheduled else { return -1.0 }
            _reconnectScheduled = true
            _isConnected = false
            _reconnectAttempt += 1
            let attempt = _reconnectAttempt
            let base = min(pow(2.0, Double(attempt)), Self.maxReconnectDelay)
            let jitter = Double.random(in: -base * 0.25 ... base * 0.25)
            return max(0.5, base + jitter)
        }
        guard delay >= 0 else { return }
        let delayStr = String(format: "%.1f", delay)
        Log.info("[AlibabaASR] 将在 \(delayStr)s 后重连...")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.connect()
        }
    }

    /// 确保已连接。已连接直接返回；否则等待当前连接握手完成（带超时），超时抛错。
    private func ensureConnected(timeout: TimeInterval) async throws {
        // 快速路径
        if stateLock.withLock({ _isConnected }) { return }
        // 若既没连接也没有正在进行的连接（webSocketTask 为空），主动发起一次
        let needConnect = stateLock.withLock { webSocketTask == nil }
        if needConnect { connect() }

        // 注册一个等待握手的 continuation；delegate 的 didOpen 会 resume 它。
        let waitID = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            var cont: CheckedContinuation<Void, Error>?
            self.stateLock.withLock {
                if let wait = self._connectWait, wait.id == waitID {
                    cont = wait.cont
                    self._connectWait = nil
                    self._connectTimeoutTask = nil
                }
            }
            cont?.resume(throwing: AlibabaASRError.connectTimeout)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateLock.withLock {
                if self._isConnected {
                    // 在拿到锁的瞬间已经连上了，直接返回
                    cont.resume()
                    timeoutTask.cancel()
                } else {
                    self._connectWait = (id: waitID, cont: cont)
                    self._connectTimeoutTask = timeoutTask
                }
            }
        }
    }

    /// 取出并 resume 当前等待连接的 continuation（didOpen/didClose 调用）。
    private func resumeConnectWait(result: Result<Void, Error>) {
        var cont: CheckedContinuation<Void, Error>?
        stateLock.withLock {
            if let wait = _connectWait {
                cont = wait.cont
                _connectWait = nil
                _connectTimeoutTask?.cancel()
                _connectTimeoutTask = nil
            }
        }
        guard let cont else { return }
        switch result {
        case .success: cont.resume()
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: - ASREngine

    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws {
        try await ensureConnected(timeout: 5)

        taskId = UUID().uuidString
        stateLock.withLock {
            _finalText = ""
            _currentPartial = ""
        }

        let runTask: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": model,
                "parameters": [
                    "format": "pcm", "sample_rate": 16000,
                    "language_hints": [languageHint(for: locale)],
                    "semantic_punctuation_enabled": semanticPunctuation,
                    "speech_noise_threshold": speechNoiseThreshold,
                    "max_sentence_silence": maxSentenceSilence
                ],
                "input": [:] as [String: Any]
            ]
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: runTask), encoding: .utf8)!
        try await webSocketTask?.send(.string(json))

        // 等待 task-started（带 10s 超时保底，避免服务端不回时永久挂起）
        let started = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.safeResumeStarted(.failure(AlibabaASRError.startTimeout))
        }
        stateLock.withLock { _startedTimeoutTask = started }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateLock.withLock { _taskStartedCont = cont }
        }
        // 已成功收到 task-started，取消超时任务
        stateLock.withLock {
            _startedTimeoutTask?.cancel()
            _startedTimeoutTask = nil
            // 服务端任务已建立：此后连接断开不再触发自动重连，改为让本次 session 抛错
            _sessionActive = true
        }

        // 存储回调
        stateLock.withLock {
            _onPartial = onPartial
            _onAudioLevel = onAudioLevel
            _onAutoStop = onAutoStop
        }
        do {
            try await startAudioCapture()
        } catch {
            // 音频采集没起来：best-effort 结束 task，回滚 session 状态，把错误抛给上层
            try? await sendFinishTask()
            stateLock.withLock { _sessionActive = false }
            throw error
        }
    }

    func stop() async throws -> String {
        capture.stop()

        // 仅当服务端任务确实建立（收到过 task-started）才发 finish-task 并等待收尾。
        // 若 start 还卡在 ensureConnected / task-started 阶段就被取消，直接清理返回。
        let shouldFinish = stateLock.withLock { _sessionActive && webSocketTask != nil }
        guard shouldFinish else {
            stateLock.withLock { _sessionActive = false }
            return stateLock.withLock { _finalText }
        }

        try await sendFinishTask()
        Log.info("[AlibabaASR] finish-task sent")

        // 等待接收循环唤醒（task-finished / task-failed / 超时 5s）
        let stopped = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.safeResumeFinished()
        }
        stateLock.withLock { _stoppedTimeoutTask = stopped }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stateLock.withLock { _taskFinishedCont = cont }
        }
        stateLock.withLock {
            _stoppedTimeoutTask?.cancel()
            _stoppedTimeoutTask = nil
            _sessionActive = false
        }

        return stateLock.withLock { _finalText }
    }

    private func sendFinishTask() async throws {
        let finishTask: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": [:] as [String: Any]]
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: finishTask), encoding: .utf8)!
        try await webSocketTask?.send(.string(json))
    }

    // MARK: - 音频

    private func startAudioCapture() async throws {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let silence: SilenceConfig? = autoStopEnabled
            ? SilenceConfig(threshold: autoStopThreshold, timeout: autoStopTimeout, gracePeriod: 1.0)
            : nil

        // onBuffer 外的锁保护回调读取；闭包把 self 状态拷出来再用，避免长锁。
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
                self.sendQueue.async { [weak self] in
                    self?.webSocketTask?.send(.data(bytes)) { _ in }
                }
            }
        )
        Log.info("[AlibabaASR] 音频引擎启动")
    }

    /// 录音中发生不可恢复的错误（连接断开、麦克风中断等）：停采集、解开会话等待者、
    /// 通过 onFailure 通知上层结束会话。best-effort，不抛错。
    private func failSession(_ error: Error) {
        capture.stop()
        var startedCont: CheckedContinuation<Void, Error>?
        var finishedCont: CheckedContinuation<Void, Never>?
        var failureCB: (@Sendable (Error) -> Void)?
        stateLock.withLock {
            guard _sessionActive else { return }
            _sessionActive = false
            startedCont = _taskStartedCont
            _taskStartedCont = nil
            finishedCont = _taskFinishedCont
            _taskFinishedCont = nil
            failureCB = _onFailure
        }
        startedCont?.resume(throwing: error)
        finishedCont?.resume()
        failureCB?(error)
    }

    // MARK: - 事件处理

    private func languageHint(for locale: Locale) -> String {
        let id = locale.language.languageCode?.identifier ?? "zh"
        switch id {
        case "zh": return "zh"
        case "en": return "en"
        case "ja": return "ja"
        case "ko": return "ko"
        case "vi": return "vi"
        case "th": return "th"
        case "id": return "id"
        case "ms": return "ms"
        case "tl": return "tl"
        case "hi": return "hi"
        case "ar": return "ar"
        case "fr": return "fr"
        case "de": return "de"
        case "es": return "es"
        case "pt": return "pt"
        case "ru": return "ru"
        case "it": return "it"
        case "nl": return "nl"
        case "sv": return "sv"
        case "da": return "da"
        case "fi": return "fi"
        case "no": return "no"
        case "el": return "el"
        case "pl": return "pl"
        case "cs": return "cs"
        case "hu": return "hu"
        case "ro": return "ro"
        case "bg": return "bg"
        case "hr": return "hr"
        case "sk": return "sk"
        default: return id
        }
    }

    /// 安全 resume task-started continuation（原子地取出并 resume，防双重 resume）。
    private func safeResumeStarted(_ result: Result<Void, Error>) {
        stateLock.withLock {
            guard let cont = _taskStartedCont else { return }
            _taskStartedCont = nil
            switch result {
            case .success: cont.resume()
            case .failure(let e): cont.resume(throwing: e)
            }
        }
    }

    /// 安全 resume task-finished continuation。
    private func safeResumeFinished() {
        stateLock.withLock {
            guard let cont = _taskFinishedCont else { return }
            _taskFinishedCont = nil
            cont.resume()
        }
    }

    private func handle(event: String, header: [String: Any], json: [String: Any]) {
        switch event {
        case "task-started":
            safeResumeStarted(.success(()))

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return }
            let text = sentence["text"] as? String ?? ""
            let isEnd = sentence["sentence_end"] as? Bool ?? false
            guard !(sentence["heartbeat"] as? Bool ?? false), !text.isEmpty else { return }

            stateLock.withLock {
                if isEnd {
                    _finalText += (_finalText.isEmpty ? "" : " ") + text
                    _currentPartial = ""
                } else {
                    _currentPartial = text
                }
                let display = _finalText + (_currentPartial.isEmpty ? "" : " " + _currentPartial)
                let cb = _onPartial
                cb?(display)
            }

        case "task-failed":
            let code = header["error_code"] as? String ?? "?"
            let msg = header["error_message"] as? String ?? ""
            Log.error("[AlibabaASR] 任务失败: \(code) - \(msg)")
            safeResumeFinished()

        case "task-finished":
            Log.info("[AlibabaASR] task-finished")
            safeResumeFinished()

        default: break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension AlibabaASREngine: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        stateLock.withLock {
            _isConnected = true
            _reconnectAttempt = 0
            _reconnectScheduled = false
            _connectTimeoutTask?.cancel()
            _connectTimeoutTask = nil
        }
        Log.info("[AlibabaASR] WebSocket 已连接")
        resumeConnectWait(result: .success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stateLock.withLock { _isConnected = false }
        resumeConnectWait(result: .failure(AlibabaASRError.notConnected))
        Log.info("[AlibabaASR] WebSocket 关闭 code=\(closeCode.rawValue)")
        // 只有活跃 session 之外的断开才重连；session 正常结束由 finish 流程处理
        let active = stateLock.withLock { _sessionActive }
        if active {
            // 录音中连接掉了：让等待中的 start/stop 抛错并通知上层；不自动重连以免半成品
            failSession(AlibabaASRError.notConnected)
        } else {
            scheduleReconnect()
        }
    }
}

enum AlibabaASRError: LocalizedError {
    case invalidURL
    case noTaskStarted
    case notConnected
    case connectTimeout
    case startTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "阿里云 ASR WebSocket URL 无效"
        case .noTaskStarted: return "阿里云 ASR 未收到 task-started"
        case .notConnected: return "阿里云 ASR 未连接"
        case .connectTimeout: return "连接阿里云 ASR 超时，请检查网络后重试"
        case .startTimeout: return "阿里云 ASR 启动超时，请重试"
        }
    }
}
