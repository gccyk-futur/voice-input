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
    let displayName = VoiceKitLocalization.string("阿里云 Fun-ASR")
    let requiresForeground = false

    var onFailure: (@Sendable (Error) -> Void)? {
        get { stateLock.withLock { _onFailure } }
        set { stateLock.withLock { _onFailure = newValue } }
    }
    private var _onFailure: (@Sendable (Error) -> Void)?

    /// 连接状态变化回调（didOpen/didClose/重连时触发），供 coordinator 刷新 UI。
    /// 参数：(是否已连接, 人类可读状态文字，如"已断开，2.4s 后重连")。
    var onConnectionChange: (@Sendable (Bool, String) -> Void)? {
        get { stateLock.withLock { _onConnectionChange } }
        set { stateLock.withLock { _onConnectionChange = newValue } }
    }
    private var _onConnectionChange: (@Sendable (Bool, String) -> Void)?

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
    /// Access is serialized by stateLock. Delegate callbacks are additionally
    /// checked against _connectionEpoch because cancelled URLSession tasks can
    /// still deliver callbacks after a replacement task has started.
    private var webSocketTask: URLSessionWebSocketTask?
    private var taskId: String = ""
    private let sendQueue = DispatchQueue(label: "com.voicemate.aliyun.send")

    // 以下字段均受 stateLock 保护
    private var _finalText: String = ""
    private var _currentPartial: String = ""
    private var _taskFinishedCont: CheckedContinuation<Void, Never>?
    private var _taskStartedCont: CheckedContinuation<Void, Error>?
    private var _stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var _taskLifecycle = ASRTaskLifecycle()
    private var _stopRequested = false
    private var _finishSent = false
    /// 当前 task 的音频发送排空组；task-finished 前必须确认所有已排队音频发送回调完成。
    private var _audioSendDrain: AudioSendDrain?
    /// 当前 task 的音频预缓冲发送门；仅阿里云远程 task 使用。
    private var _audioPreRollGate: AudioPreRollSendGate?
    /// 等待握手完成的 continuation（ensureConnected 注册，didOpen/超时 resume）。
    private var _connectWait: (id: UUID, cont: CheckedContinuation<Void, Error>)?
    private var _isConnected = false
    /// 是否已有一次重连在排队（防止 didClose 与接收循环双触发）。
    private var _reconnectScheduled = false
    private var _connectionEpoch = ConnectionEpoch()
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
    private var _handshakeTimeoutTask: Task<Void, Never>?

    /// session 活跃标记：接收循环据此在 finish 后退出，而非触发重连。
    private var _sessionActive = false
    /// 当前 task 已发出的音频字节数：用于区分「零音频空会话」与真实任务失败。
    private var _audioBytesSent = 0

    var wsConnected: Bool { stateLock.withLock { _isConnected } }

    /// 复用前健康检查：连接在且生命周期允许开新任务才复用；
    /// 否则由协调器新建引擎，避免把作废的连接状态带进下一次会话。
    var canStartNewSession: Bool {
        stateLock.withLock { _isConnected && _taskLifecycle.canStart }
    }

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
        let task: URLSessionWebSocketTask? = stateLock.withLock {
            _receiveTask?.cancel()
            _startedTimeoutTask?.cancel()
            _stoppedTimeoutTask?.cancel()
            _connectTimeoutTask?.cancel()
            _handshakeTimeoutTask?.cancel()
            _taskStartedCont?.resume(throwing: AlibabaASRError.notConnected)
            _taskStartedCont = nil
            _taskFinishedCont?.resume()
            _taskFinishedCont = nil
            _stopWaiters.forEach { $0.resume() }
            _stopWaiters.removeAll()
            _connectWait?.cont.resume(throwing: AlibabaASRError.notConnected)
            _connectWait = nil
            _connectionEpoch = ConnectionEpoch()
            _reconnectScheduled = true
            let task = webSocketTask
            webSocketTask = nil
            return task
        }
        task?.cancel()
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

        // 取消旧的接收循环和 WebSocket 任务，避免多个连接并存；session 复用不重建。
        // Store the replacement and its epoch under one lock before resuming it,
        // so a very fast didOpen callback cannot observe a half-installed task.
        let newTask = session.webSocketTask(with: req)
        let connectionEpoch: UUID
        let oldTask: URLSessionWebSocketTask?
        let oldReceiveTask: Task<Void, Never>?
        let handshakeWatchdog: Task<Void, Never>
        stateLock.lock()
        oldReceiveTask = _receiveTask
        _receiveTask = nil
        oldTask = webSocketTask
        webSocketTask = newTask
        connectionEpoch = _connectionEpoch.begin()
        _isConnected = false
        _reconnectScheduled = false
        _handshakeTimeoutTask?.cancel()
        handshakeWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            let shouldReconnect = self.stateLock.withLock {
                guard self._connectionEpoch.accepts(connectionEpoch) else { return false }
                self._handshakeTimeoutTask = nil
                return !self._isConnected
            }
            if shouldReconnect {
                Log.info("[AlibabaASR] 握手超时，安排重连")
                self.scheduleReconnect()
            }
        }
        _handshakeTimeoutTask = handshakeWatchdog
        stateLock.unlock()

        oldReceiveTask?.cancel()
        oldTask?.cancel()
        newTask.resume()
        Log.info("[AlibabaASR] 正在连接 WebSocket…")
        notifyConnectionChange(false, VoiceKitLocalization.string("连接中…"))

        // 统一接收循环：只消费这个 epoch 对应的 WebSocket；旧循环退出时
        // receiveLoopEnded 会丢弃其重连请求。
        let receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            while true {
                if Task.isCancelled { break }

                let msg: URLSessionWebSocketTask.Message
                do {
                    msg = try await newTask.receive()
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
                    self.handle(
                        event: event,
                        header: header,
                        json: json,
                        connectionEpoch: connectionEpoch
                    )
                case .data: break
                @unknown default: break
                }
            }
            self.receiveLoopEnded(connectionEpoch: connectionEpoch)
        }
        let installed = stateLock.withLock { () -> Bool in
            guard _connectionEpoch.accepts(connectionEpoch) else { return false }
            _receiveTask = receiveTask
            return true
        }
        if !installed {
            receiveTask.cancel()
        }
    }

    /// Handles the end of one receive loop only if it is still the current
    /// connection. A cancelled old loop must never schedule another reconnect.
    private func receiveLoopEnded(connectionEpoch: UUID) {
        let shouldReconnect = stateLock.withLock {
            guard _connectionEpoch.accepts(connectionEpoch) else { return false }
            if _sessionActive {
                Log.info("[AlibabaASR] session 结束，不触发重连")
                return false
            }
            return true
        }
        guard shouldReconnect else { return }
        guard !Task.isCancelled else { return }
        Log.error("[AlibabaASR] 连接异常断开，将重连")
        scheduleReconnect()
    }

    private func currentWebSocketTask() -> URLSessionWebSocketTask? {
        stateLock.withLock { webSocketTask }
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
        notifyConnectionChange(false, VoiceKitLocalization.format("已断开，%@s 后自动重连", delayStr))
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            let shouldConnect = self.stateLock.withLock {
                self._reconnectScheduled && !self._isConnected
            }
            guard shouldConnect else { return }
            self.connect()
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

    /// 原子地尝试开启一个服务端 task 生命周期，成功后初始化本 task 的全部状态。
    private func tryBeginTask(taskID: String, gate: AudioPreRollSendGate) -> ASRTaskLifecycle.Transition {
        stateLock.withLock {
            let result = _taskLifecycle.begin(taskID: taskID)
            guard result == .accepted else { return result }
            taskId = taskID
            _finalText = ""
            _currentPartial = ""
            _stopRequested = false
            _finishSent = false
            _audioBytesSent = 0
            _audioSendDrain = AudioSendDrain()
            _audioPreRollGate = gate
            return result
        }
    }

    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws {
        // 没有麦克风时不要先向服务端创建一个必然 EmptyAudio 的 task。
        try capture.ensureInputAvailable()

        let newTaskID = UUID().uuidString
        let audioGate = AudioPreRollSendGate(sendQueue: sendQueue) { [weak self] data in
            self?.sendAudioData(data, taskID: newTaskID)
        }
        var beginResult = tryBeginTask(taskID: newTaskID, gate: audioGate)
        if case .rejected(.requiresReconnect) = beginResult {
            // 上一次会话失败作废了常驻连接（task-failed 后必须换连接）：
            // 等待后台重连完成（ensureConnected 会等当前握手），然后重试一次 begin，
            // 而不是把「正在重连」直接抛成 busy 错误页。
            Log.info("[AlibabaASR] 连接重建中，等待后重试开任务")
            try await ensureConnected(timeout: 8)
            beginResult = tryBeginTask(taskID: newTaskID, gate: audioGate)
        }
        guard beginResult == .accepted else {
            throw AlibabaASRError.busy
        }
        Log.info("[AlibabaASR] task=\(newTaskID) 音频预缓冲已创建")

        let runTask: [String: Any] = [
            "header": ["action": "run-task", "task_id": newTaskID, "streaming": "duplex"],
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
        do {
            // 回调必须在远程 task 握手前安装，启动期间的 PCM 先进入本地预缓冲。
            stateLock.withLock {
                _onPartial = onPartial
                _onAudioLevel = onAudioLevel
                _onAutoStop = onAutoStop
            }
            try await startAudioCapture(gate: audioGate, taskID: newTaskID)

            // 采集启动后，用户可能立即结束会话，或音频回调可能报告了不可恢复错误。
            // 这两种情况都不能让启动协程继续创建远程 task。
            guard canContinueStarting(taskID: newTaskID) else {
                throw AlibabaASRError.cancelled
            }

            // 采集已由 gate 接住；首次建连也不能再吞掉用户的开头语音。
            try await ensureConnected(timeout: 5)

            guard canContinueStarting(taskID: newTaskID) else {
                throw AlibabaASRError.cancelled
            }

            // continuation 必须先注册，再发送 run-task，避免服务端事件先到导致丢失。
            try await sendRunTaskAndWait(json: json, taskID: newTaskID)
            let stopWasRequested = stateLock.withLock {
                _sessionActive = true
                return _stopRequested
            }
            if stopWasRequested {
                // cancel 可能发生在 task-started 到达、但 start 尚未恢复的窗口。
                await finishTaskAndWait(taskID: newTaskID)
                throw AlibabaASRError.cancelled
            }

            let bufferedBytes = audioGate.bufferedByteCount
            Log.info("[AlibabaASR] task=\(newTaskID) 音频预缓冲开始排空，bytes=\(bufferedBytes)")
            guard await audioGate.serverReady() else {
                throw AlibabaASRError.cancelled
            }
            Log.info("[AlibabaASR] task=\(newTaskID) 音频预缓冲已排空，进入实时发送")
        } catch {
            // 启动失败必须停采集：否则 tap 残留，麦克风常亮，
            // 且下次 start 对已装 tap 的 inputNode 再 installTap 会抛 NSException。
            capture.stop()
            audioGate.discard()
            Log.info("[AlibabaASR] task=\(newTaskID) 音频预缓冲已丢弃，启动未完成")
            stateLock.withLock {
                if _audioPreRollGate === audioGate {
                    _audioPreRollGate = nil
                }
            }
            let taskWasStarted = stateLock.withLock { _sessionActive }
            if taskWasStarted {
                // 音频采集或取消失败：先正常结束服务端 task，再把错误抛给上层。
                await finishTaskAndWait(taskID: newTaskID)
            } else {
                stateLock.withLock { _ = _taskLifecycle.startFailed(taskID: newTaskID) }
            }
            throw error
        }
    }

    func stop() async throws -> String {
        capture.stop()
        let audioGate = stateLock.withLock { _audioPreRollGate }
        audioGate?.discard()

        let taskToFinish = stateLock.withLock { () -> String? in
            switch _taskLifecycle.phase {
            case .starting(let id), .running(let id), .finishing(let id):
                _stopRequested = true
                _ = _taskLifecycle.requestFinish(taskID: id)
                return id
            case .idle, .failed:
                _sessionActive = false
                return nil
            }
        }
        guard let taskToFinish else {
            return stateLock.withLock { _finalText }
        }
        Log.info("[AlibabaASR] task=\(taskToFinish) 音频预缓冲已丢弃，用户结束")

        await finishTaskAndWait(taskID: taskToFinish)
        return stateLock.withLock { _finalText }
    }

    private func sendRunTaskAndWait(json: String, taskID: String) async throws {
        guard let webSocketTask = currentWebSocketTask() else {
            throw AlibabaASRError.notConnected
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let installed = stateLock.withLock { () -> Bool in
                    guard _taskStartedCont == nil else { return false }
                    _taskStartedCont = cont
                    _startedTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.safeResumeStarted(.failure(AlibabaASRError.startTimeout))
                    }
                    return true
                }
                guard installed else {
                    cont.resume(throwing: AlibabaASRError.busy)
                    return
                }
                Task { [weak self] in
                    do {
                        try await webSocketTask.send(.string(json))
                    } catch {
                        self?.safeResumeStarted(.failure(error))
                    }
                }
            }
        }, onCancel: { [weak self] in
            self?.requestStopForPendingStart(taskID: taskID)
        })
    }

    private func finishTaskAndWait(taskID: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldSend = stateLock.withLock { () -> Bool in
                _stopWaiters.append(cont)
                if _stoppedTimeoutTask == nil {
                    _stoppedTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.finishWaitTimedOut(taskID: taskID)
                    }
                }
                guard !_finishSent else { return false }
                // If stop arrived while run-task was still starting, the
                // task-started handler will send finish-task after the server
                // has accepted the task.
                guard _sessionActive else { return false }
                _finishSent = true
                return true
            }
            if shouldSend {
                sendFinishTaskOnce(taskID: taskID)
            }
        }
    }

    private func sendFinishTaskOnce(taskID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.waitForAudioDrain()
                try await self.sendFinishTask(taskID: taskID)
                Log.info("[AlibabaASR] finish-task sent")
            } catch {
                Log.error("[AlibabaASR] finish-task 发送失败: \(error)")
                self.finishWaitTimedOut(taskID: taskID)
            }
        }
    }

    /// 在发送队列上提交一块当前 task 的 PCM 音频。
    /// 预缓冲和实时音频都经过这里，保证 finish-task 不会越过已经开始的发送。
    private func sendAudioData(_ bytes: Data, taskID: String) {
        let result: (URLSessionWebSocketTask?, AudioSendDrain?) = stateLock.withLock {
            guard self.taskId == taskID else { return (nil, nil) }
            _audioBytesSent += bytes.count
            return (self.webSocketTask, self._audioSendDrain)
        }
        let webSocketTask = result.0
        let drain = result.1
        guard let webSocketTask, let drain, drain.begin() else { return }
        webSocketTask.send(.data(bytes)) { _ in
            drain.end()
        }
    }

    private func canContinueStarting(taskID: String) -> Bool {
        stateLock.withLock {
            guard self.taskId == taskID else { return false }
            guard case let .starting(activeTaskID) = _taskLifecycle.phase,
                  activeTaskID == taskID else {
                return false
            }
            return !_stopRequested
        }
    }

    /// 等待当前 task 已经交给 URLSession 的全部音频帧完成回调。
    /// 若发送失败，回调同样会 leave，因此不会永久阻塞 finish 流程。
    private func waitForAudioDrain() async {
        let drain = stateLock.withLock { _audioSendDrain }
        guard let drain else { return }
        await drain.closeAndWait()
    }

    private func sendFinishTask(taskID: String) async throws {
        let finishTask: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [:] as [String: Any]]
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: finishTask), encoding: .utf8)!
        guard let webSocketTask = currentWebSocketTask() else {
            throw AlibabaASRError.notConnected
        }
        try await webSocketTask.send(.string(json))
    }

    // MARK: - 音频

    private func startAudioCapture(gate: AudioPreRollSendGate, taskID: String) async throws {
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
                if case .overflow = gate.append(bytes) {
                    Log.error("[AlibabaASR] task=\(taskID) 音频预缓冲已满，终止当前启动")
                    self.failSession(AlibabaASRError.audioPreRollOverflow)
                }
            }
        )
        Log.info("[AlibabaASR] 音频引擎启动，等待远程 task")
    }

    /// 触发连接状态变化回调（在锁外执行，避免持锁回调上层）。
    private func notifyConnectionChange(_ connected: Bool, _ status: String) {
        let cb = onConnectionChange
        cb?(connected, status)
    }

    /// 录音中发生不可恢复的错误（连接断开、麦克风中断等）：停采集、解开会话等待者、
    /// 通过 onFailure 通知上层结束会话。best-effort，不抛错。
    private func failSession(_ error: Error) {
        capture.stop()
        var startedCont: CheckedContinuation<Void, Error>?
        var finishedCont: CheckedContinuation<Void, Never>?
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var failureCB: (@Sendable (Error) -> Void)?
        var audioGate: AudioPreRollSendGate?
        var failedTaskID: String?
        var taskWasActive = false
        stateLock.withLock {
            switch _taskLifecycle.phase {
            case .idle, .failed:
                return
            case .starting, .running, .finishing:
                taskWasActive = true
            }
            guard taskWasActive else { return }
            if case let .starting(taskID) = _taskLifecycle.phase {
                _ = _taskLifecycle.taskFailed(taskID: taskID)
            } else if case let .running(taskID) = _taskLifecycle.phase {
                _ = _taskLifecycle.taskFailed(taskID: taskID)
            } else if case let .finishing(taskID) = _taskLifecycle.phase {
                _ = _taskLifecycle.taskFailed(taskID: taskID)
            }
            failedTaskID = taskId
            _sessionActive = false
            _stopRequested = false
            _finishSent = false
            _audioSendDrain = nil
            audioGate = _audioPreRollGate
            _audioPreRollGate = nil
            _startedTimeoutTask?.cancel()
            _startedTimeoutTask = nil
            _stoppedTimeoutTask?.cancel()
            _stoppedTimeoutTask = nil
            startedCont = _taskStartedCont
            _taskStartedCont = nil
            finishedCont = _taskFinishedCont
            _taskFinishedCont = nil
            stopWaiters = _stopWaiters
            _stopWaiters.removeAll()
            failureCB = _onFailure
        }
        guard taskWasActive else { return }
        audioGate?.discard()
        if let failedTaskID {
            Log.info("[AlibabaASR] task=\(failedTaskID) 音频预缓冲已丢弃，会话失败")
        }
        startedCont?.resume(throwing: error)
        finishedCont?.resume()
        stopWaiters.forEach { $0.resume() }
        failureCB?(error)
    }

    private func requestStopForPendingStart(taskID: String) {
        stateLock.withLock {
            guard taskId == taskID else { return }
            guard case .starting = _taskLifecycle.phase else { return }
            _stopRequested = true
            _ = _taskLifecycle.requestFinish(taskID: taskID)
        }
    }

    private func resolveFinishWaiters(taskID: String, succeeded: Bool) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var audioGate: AudioPreRollSendGate?
        stateLock.withLock {
            guard self.taskId == taskID else { return }
            if succeeded {
                _ = _taskLifecycle.taskFinished(taskID: taskID)
            } else {
                _ = _taskLifecycle.taskFailed(taskID: taskID)
            }
            _sessionActive = false
            _finishSent = false
            _stopRequested = false
            _audioSendDrain = nil
            audioGate = _audioPreRollGate
            _audioPreRollGate = nil
            _stoppedTimeoutTask?.cancel()
            _stoppedTimeoutTask = nil
            waiters = _stopWaiters
            _stopWaiters.removeAll()
        }
        audioGate?.discard()
        waiters.forEach { $0.resume() }
    }

    private func finishWaitTimedOut(taskID: String) {
        let isCurrentTask = stateLock.withLock { self.taskId == taskID }
        guard isCurrentTask else { return }
        resolveFinishWaiters(taskID: taskID, succeeded: false)
        currentWebSocketTask()?.cancel(with: .goingAway, reason: nil)
        scheduleReconnect()
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
            _startedTimeoutTask?.cancel()
            _startedTimeoutTask = nil
            switch result {
            case .success: cont.resume()
            case .failure(let e): cont.resume(throwing: e)
            }
        }
    }

    /// 安全 resume task-finished continuation。
    private func safeResumeFinished() {
        let taskID = stateLock.withLock { taskId }
        finishWaitTimedOut(taskID: taskID)
    }

    private func handle(
        event: String,
        header: [String: Any],
        json: [String: Any],
        connectionEpoch: UUID
    ) {
        guard stateLock.withLock({ _connectionEpoch.accepts(connectionEpoch) }) else { return }
        switch event {
        case "task-started":
            let currentTaskID = header["task_id"] as? String ?? stateLock.withLock { taskId }
            let shouldFinish = stateLock.withLock { () -> Bool in
                guard currentTaskID == taskId else { return false }
                guard _taskLifecycle.taskStarted(taskID: currentTaskID) == .accepted else {
                    return false
                }
                _sessionActive = true
                return _stopRequested
            }
            safeResumeStarted(.success(()))
            if shouldFinish {
                stateLock.withLock { _finishSent = true }
                sendFinishTaskOnce(taskID: currentTaskID)
            }

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
            let currentTaskID = header["task_id"] as? String ?? stateLock.withLock { taskId }
            let code = header["error_code"] as? String ?? "?"
            let msg = header["error_message"] as? String ?? ""
            let taskError = AlibabaASRError.taskFailed(code: code, message: msg)
            Log.error("[AlibabaASR] 任务失败: \(code) - \(msg)")
            var failureCB: (@Sendable (Error) -> Void)?
            let (shouldHandle, isSilentEmptySession) = stateLock.withLock { () -> (Bool, Bool) in
                guard currentTaskID == taskId else { return (false, false) }
                switch _taskLifecycle.phase {
                case .idle, .failed:
                    return (false, false)
                case .starting, .running, .finishing:
                    break
                }
                // 零音频空会话：用户按下停止时从未发出过任何音频（例如呼出后
                // 没说话就关闭），服务端必然以 EmptyAudio 类 task-failed 收尾。
                // 这是用户主动取消的正常结果而非故障：协议收尾（断连重连）照旧，
                // 但不上报 onFailure，避免把「没说话就关掉」显示成错误页。
                let silent: Bool
                if case .finishing = _taskLifecycle.phase, _audioBytesSent == 0 {
                    silent = true
                } else {
                    silent = false
                    failureCB = _onFailure
                }
                _ = _taskLifecycle.taskFailed(taskID: currentTaskID)
                _sessionActive = false
                return (true, silent)
            }
            guard shouldHandle else { return }
            if isSilentEmptySession {
                Log.info("[AlibabaASR] 零音频空会话，静默收尾（不上报失败）")
            }
            capture.stop()
            safeResumeStarted(.failure(taskError))
            resolveFinishWaiters(taskID: currentTaskID, succeeded: false)
            if !isSilentEmptySession {
                failureCB?(taskError)
            }
            currentWebSocketTask()?.cancel(with: .goingAway, reason: nil)
            scheduleReconnect()

        case "task-finished":
            Log.info("[AlibabaASR] task-finished")
            let currentTaskID = header["task_id"] as? String ?? stateLock.withLock { taskId }
            resolveFinishWaiters(taskID: currentTaskID, succeeded: true)

        default: break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension AlibabaASREngine: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let isCurrent = stateLock.withLock {
            guard self.webSocketTask === webSocketTask else { return false }
            _ = _taskLifecycle.reconnectSucceeded()
            _isConnected = true
            _reconnectAttempt = 0
            _reconnectScheduled = false
            _connectTimeoutTask?.cancel()
            _connectTimeoutTask = nil
            _handshakeTimeoutTask?.cancel()
            _handshakeTimeoutTask = nil
            return true
        }
        guard isCurrent else { return }
        Log.info("[AlibabaASR] WebSocket 已连接")
        resumeConnectWait(result: .success(()))
        notifyConnectionChange(true, VoiceKitLocalization.string("已连接"))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let isCurrent = stateLock.withLock {
            guard self.webSocketTask === webSocketTask else { return false }
            _isConnected = false
            _handshakeTimeoutTask?.cancel()
            _handshakeTimeoutTask = nil
            return true
        }
        guard isCurrent else { return }
        resumeConnectWait(result: .failure(AlibabaASRError.notConnected))
        Log.info("[AlibabaASR] WebSocket 关闭 code=\(closeCode.rawValue)")
        notifyConnectionChange(false, VoiceKitLocalization.string("已断开"))
        // 只要仍有 task 在途，断开就必须解开 start/stop 等待者；
        // session 正常结束时生命周期已回到 idle，由 finish 流程处理。
        let taskInFlight = stateLock.withLock { () -> Bool in
            switch _taskLifecycle.phase {
            case .idle, .failed:
                return false
            case .starting, .running, .finishing:
                return true
            }
        }
        if taskInFlight {
            // 录音中连接掉了：让等待中的 start/stop 抛错并通知上层结束本次会话；
            // 同时后台重连常驻连接，保证下次呼出能直接用（不会半成品——session 已 fail）
            failSession(AlibabaASRError.notConnected)
            scheduleReconnect()
        } else {
            scheduleReconnect()
        }
    }
}

enum AlibabaASRError: LocalizedError {
    case invalidURL
    case noTaskStarted
    case notConnected
    case busy
    case cancelled
    case connectTimeout
    case startTimeout
    case audioPreRollOverflow
    case taskFailed(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return VoiceKitLocalization.string("阿里云 ASR WebSocket URL 无效")
        case .noTaskStarted: return VoiceKitLocalization.string("阿里云 ASR 未收到 task-started")
        case .notConnected: return VoiceKitLocalization.string("阿里云 ASR 未连接")
        case .busy: return VoiceKitLocalization.string("阿里云 ASR 上一个任务尚未结束，请稍后重试")
        case .cancelled: return VoiceKitLocalization.string("阿里云 ASR 任务已取消")
        case .connectTimeout: return VoiceKitLocalization.string("连接阿里云 ASR 超时，请检查网络后重试")
        case .startTimeout: return VoiceKitLocalization.string("阿里云 ASR 启动超时，请重试")
        case .audioPreRollOverflow: return VoiceKitLocalization.string("阿里云 ASR 启动较慢，请重试")
        case .taskFailed(_, let message): return VoiceKitLocalization.format("阿里云 ASR 任务失败：%@", message)
        }
    }
}
