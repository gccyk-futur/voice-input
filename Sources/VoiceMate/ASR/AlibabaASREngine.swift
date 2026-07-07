import Foundation
import AVFAudio

/// 阿里云百炼 Fun-ASR 实时语音识别引擎（WebSocket 长连接）。
///
/// 连接常驻，每次 start/stop 只收发 run-task / finish-task，不复重连。
/// semantic_punctuation_enabled 自动加标点，结果用空格拼接而非换行。
final class AlibabaASREngine: ASREngine, @unchecked Sendable {
    let id = "aliyun"
    let displayName = "阿里云 Fun-ASR"
    let requiresForeground = false

    private let apiKey: String
    private let workspaceId: String
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

    private var finalText: String = ""
    private var currentPartial: String = ""
    private var taskFinishedCont: CheckedContinuation<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false

    // 静音检测
    private var onAudioLevel: (@Sendable (Float) -> Void)?
    private var onAutoStop: (@Sendable () -> Bool)?
    private var silenceStart: Date?

    init(apiKey: String, workspaceId: String, model: String,
         semanticPunctuation: Bool = true, speechNoiseThreshold: Double = 0, maxSentenceSilence: Int = 1300,
         autoStopEnabled: Bool = true, autoStopTimeout: TimeInterval = 3.5, autoStopThreshold: Float = 0.01) {
        self.apiKey = apiKey
        self.workspaceId = workspaceId
        self.model = model
        self.semanticPunctuation = semanticPunctuation
        self.speechNoiseThreshold = speechNoiseThreshold
        self.maxSentenceSilence = maxSentenceSilence
        self.autoStopEnabled = autoStopEnabled
        self.autoStopTimeout = autoStopTimeout
        self.autoStopThreshold = autoStopThreshold
        connect()
    }

    // MARK: - 常驻连接

    private func connect() {
        guard let url = URL(string: "wss://\(workspaceId).cn-beijing.maas.aliyuncs.com/api-ws/v1/inference") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        session = URLSession(configuration: .default)
        webSocketTask = session?.webSocketTask(with: req)
        webSocketTask?.resume()
        isConnected = true
        print("[AlibabaASR] WebSocket 已连接")

        // 统一接收循环：处理所有服务端事件
        receiveTask = Task.detached { [weak self] in
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
                self.isConnected = false
                // 自动重连
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { self.connect() }
            }
        }
    }

    // MARK: - ASREngine

    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws {
        guard isConnected else { throw AlibabaASRError.notConnected }
        taskId = UUID().uuidString
        finalText = ""
        currentPartial = ""

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

        // 等待 task-started
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.taskStartedCont = cont
        }
        // 超时保底
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.taskStartedCont?.resume(throwing: AlibabaASRError.noTaskStarted)
            self.taskStartedCont = nil
        }

        // 存储回调
        self.onPartial = onPartial
        self.onAudioLevel = onAudioLevel
        self.onAutoStop = onAutoStop
        self.silenceStart = nil
        await startAudioCapture()
    }

    func stop() async throws -> String {
        guard webSocketTask != nil else { return finalText }
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
            self.taskFinishedCont = cont
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.taskFinishedCont?.resume()
            self.taskFinishedCont = nil
        }

        return finalText
    }

    // MARK: - 音频

    private func startAudioCapture() async {
        // 清理旧的 tap（如果有）
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()  // 强制重新查询硬件格式

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
            self.onAudioLevel?(level)

            // 静音检测 → 自动停止
            if self.autoStopEnabled && level < self.autoStopThreshold {
                if self.silenceStart == nil { self.silenceStart = Date() }
                if let start = self.silenceStart,
                   Date().timeIntervalSince(start) >= self.autoStopTimeout {
                    if self.onAutoStop?() == true {
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

    private var taskStartedCont: CheckedContinuation<Void, Error>?
    private var onPartial: (@Sendable (String) -> Void)?

    private func handle(event: String, header: [String: Any], json: [String: Any]) {
        switch event {
        case "task-started":
            taskStartedCont?.resume()
            taskStartedCont = nil

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return }
            let text = sentence["text"] as? String ?? ""
            let isEnd = sentence["sentence_end"] as? Bool ?? false
            guard !(sentence["heartbeat"] as? Bool ?? false), !text.isEmpty else { return }

            if isEnd {
                finalText += (finalText.isEmpty ? "" : " ") + text
                currentPartial = ""
            } else {
                currentPartial = text
            }
            let display = finalText + (currentPartial.isEmpty ? "" : " " + currentPartial)
            onPartial?(display)

        case "task-failed":
            let code = header["error_code"] as? String ?? "?"
            let msg = header["error_message"] as? String ?? ""
            print("[AlibabaASR] 任务失败: \(code) - \(msg)")
            taskFinishedCont?.resume()
            taskFinishedCont = nil

        case "task-finished":
            print("[AlibabaASR] task-finished")
            taskFinishedCont?.resume()
            taskFinishedCont = nil

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
