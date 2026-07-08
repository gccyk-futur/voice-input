import Foundation
@preconcurrency import AVFAudio

/// 阿里云百炼 Fun-ASR 实时语音识别引擎（WebSocket 长连接）。
///
/// 连接常驻，每次 start/stop 只收发 run-task / finish-task，不复重连。
/// semantic_punctuation_enabled 自动加标点，结果用空格拼接而非换行。
final class AlibabaASREngine: ASREngine, @unchecked Sendable {
    let id = "aliyun"
    let displayName = "阿里云 Fun-ASR"
    let requiresForeground = false

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

    private let audioEngine = AVAudioEngine()
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var taskId: String = ""
    private let sendQueue = DispatchQueue(label: "com.voicemate.aliyun.send")

    // 以下字段均受 stateLock 保护
    private var _finalText: String = ""
    private var _currentPartial: String = ""
    private var _taskFinishedCont: CheckedContinuation<Void, Never>?
    private var _taskStartedCont: CheckedContinuation<Void, Error>?
    private var _isConnected = false
    private var _onPartial: (@Sendable (String) -> Void)?
    private var _onAudioLevel: (@Sendable (Float) -> Void)?
    private var _onAutoStop: (@Sendable () -> Bool)?
    private var _receiveTask: Task<Void, Never>?
    /// 重连指数退避计数器（0=首次连接）
    private var _reconnectAttempt: Int = 0

    // 超时 Task 引用 — 用于取消
    private var _startedTimeoutTask: Task<Void, Never>?
    private var _stoppedTimeoutTask: Task<Void, Never>?

    // 静音检测（仅在音频 tap 回调中访问，tap 串行化，无需锁）
    private var silenceStart: Date?

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
        connect()
    }

    deinit {
        stateLock.withLock {
            _receiveTask?.cancel()
            _startedTimeoutTask?.cancel()
            _stoppedTimeoutTask?.cancel()
            _taskStartedCont?.resume(throwing: AlibabaASRError.notConnected)
            _taskStartedCont = nil
            _taskFinishedCont?.resume()
            _taskFinishedCont = nil
        }
    }

    /// 重连最大退避时间（秒）
    private static let maxReconnectDelay: TimeInterval = 30

    // MARK: - 常驻连接

    private func connect() {
        guard let url = URL(string: "wss://\(workspaceId).\(region).maas.aliyuncs.com/api-ws/v1/inference") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        // 取消已有接收循环，避免多个同时运行
        stateLock.withLock {
            _receiveTask?.cancel()
            _receiveTask = nil
        }

        session = URLSession(configuration: .default)
        webSocketTask = session?.webSocketTask(with: req)
        webSocketTask?.resume()
        stateLock.withLock {
            _isConnected = true
            _reconnectAttempt = 0
        }
        print("[AlibabaASR] WebSocket 已连接")

        // 统一接收循环：处理所有服务端事件
        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let msg = try await self.webSocketTask?.receive()
                    guard let msg else { break }
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
            } catch {
                print("[AlibabaASR] 接收循环断开: \(error)")
                self.stateLock.withLock {
                    self._isConnected = false
                    self._reconnectAttempt += 1
                }
                // 自动重连（指数退避 + jitter）
                let delay = self.nextReconnectDelay()
                let delayStr = String(format: "%.1f", delay)
                print("[AlibabaASR] 将在 \(delayStr)s 后重连...")
                try? await Task.sleep(for: .seconds(delay))
                self.connect()
            }
        }
        stateLock.withLock { _receiveTask = task }
    }

    /// 指数退避（1s → 2s → 4s → … → max 30s）+ 随机 jitter（±25%）
    private func nextReconnectDelay() -> TimeInterval {
        let attempt = stateLock.withLock { _reconnectAttempt }
        let base = min(pow(2.0, Double(attempt)), Self.maxReconnectDelay)
        let jitter = Double.random(in: -base * 0.25 ... base * 0.25)
        return max(0.5, base + jitter)
    }

    // MARK: - ASREngine

    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws {
        guard stateLock.withLock({ _isConnected }) else { throw AlibabaASRError.notConnected }
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

        // 等待 task-started（带超时保底）
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateLock.withLock { _taskStartedCont = cont }
        }
        // 已成功收到 task-started，取消超时任务
        stateLock.withLock {
            _startedTimeoutTask?.cancel()
            _startedTimeoutTask = nil
        }

        // 存储回调
        stateLock.withLock {
            _onPartial = onPartial
            _onAudioLevel = onAudioLevel
            _onAutoStop = onAutoStop
        }
        self.silenceStart = nil
        await startAudioCapture()
    }

    func stop() async throws -> String {
        guard webSocketTask != nil else { return stateLock.withLock { _finalText } }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let finishTask: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": [:] as [String: Any]]
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: finishTask), encoding: .utf8)!
        try? await webSocketTask?.send(.string(json))
        print("[AlibabaASR] finish-task sent")

        // 等待接收循环唤醒（task-finished / task-failed / 超时 5s）
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stateLock.withLock { _taskFinishedCont = cont }
        }
        // 已收到 task-finished，取消超时任务
        stateLock.withLock {
            _stoppedTimeoutTask?.cancel()
            _stoppedTimeoutTask = nil
        }

        return stateLock.withLock { _finalText }
    }

    // MARK: - 音频

    private func startAudioCapture() async {
        // 清理旧的 tap（如果有）
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) {
            [weak self, converter, targetFormat, hardwareFormat] buffer, _ in
            guard let self else { return }
            let ratio = targetFormat.sampleRate / hardwareFormat.sampleRate
            let fc = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard fc > 0, let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: fc) else { return }
            var didProvide = false
            var convErr: NSError?
            converter.convert(to: out, error: &convErr) { _, st in
                guard !didProvide else { st.pointee = .noDataNow; return nil }
                didProvide = true; st.pointee = .haveData; return buffer
            }
            guard convErr == nil, out.frameLength > 0 else { return }
            let len = Int(out.frameLength)
            guard let ch = out.int16ChannelData?.pointee else { return }

            // 计算 RMS 电平（0.0~1.0）
            var sum: Float = 0
            for i in 0..<len { let s = Float(ch[i]); sum += s * s }
            let rms = sqrt(sum / Float(len)) / 32768.0
            let level = min(rms, 1.0)

            // 在锁下读取回调引用，避免数据竞争
            var levelCB: (@Sendable (Float) -> Void)?
            var autoStopCB: (@Sendable () -> Bool)?
            self.stateLock.withLock {
                levelCB = self._onAudioLevel
                autoStopCB = self._onAutoStop
            }
            levelCB?(level)

            // 静音检测 → 自动停止
            if self.autoStopEnabled && level < self.autoStopThreshold {
                if self.silenceStart == nil { self.silenceStart = Date() }
                if let start = self.silenceStart,
                   Date().timeIntervalSince(start) >= self.autoStopTimeout {
                    if autoStopCB?() == true {
                        self.silenceStart = nil
                    }
                }
            } else {
                self.silenceStart = nil
            }

            let bytes = Data(bytes: ch, count: len * 2)
            self.sendQueue.async { self.webSocketTask?.send(.data(bytes)) { _ in } }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("[AlibabaASR] 音频引擎启动")
        } catch {
            print("[AlibabaASR] 音频引擎启动失败: \(error)")
        }
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
            print("[AlibabaASR] 任务失败: \(code) - \(msg)")
            safeResumeFinished()

        case "task-finished":
            print("[AlibabaASR] task-finished")
            safeResumeFinished()

        default: break
        }
    }
}

enum AlibabaASRError: LocalizedError {
    case invalidURL
    case noTaskStarted
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "阿里云 ASR WebSocket URL 无效"
        case .noTaskStarted: return "阿里云 ASR 未收到 task-started"
        case .notConnected: return "阿里云 ASR 未连接"
        }
    }
}
