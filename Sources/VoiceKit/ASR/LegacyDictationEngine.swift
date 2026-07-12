import Foundation
@preconcurrency import AVFAudio
@preconcurrency import Speech

/// 经典系统听写引擎：基于 SFSpeechRecognizer（走 Apple 服务器识别）。
///
/// 为什么需要它：macOS 26 的 on-device SpeechAnalyzer / SpeechTranscriber 在中文上
/// 经常缺少 GeneralASR 资产（模型需单独下载，且中文支持缺失时直接抛异常），
/// 因此当 SpeechTranscriber 不支持当前语言（尤其中文）时，回退到本引擎——
/// SFSpeechRecognizer 对 zh-CN 等区域码有稳定的服务器识别能力。
///
/// 与 SystemDictationEngine 一样，本类不隔离到主线程，避免阻塞 UI。
final class LegacyDictationEngine: ASREngine, @unchecked Sendable {
    let id = "system-legacy"
    let displayName = "系统听写（服务器）"
    let requiresForeground = false
    private let audioEngine = AVAudioEngine()
    private let appendQueue = DispatchQueue(label: "com.voicemate.speech.append")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalText: String = ""
    private var finishContinuation: CheckedContinuation<String, Never>?
    // 静音检测
    private var onAudioLevel: (@Sendable (Float) -> Void)?
    private var onAutoStop: (@Sendable () -> Bool)?
    private var silenceStart: Date?
    private var silenceAutoStopEnabled = true
    private var silenceTimeout: TimeInterval = 2.0
    private var silenceThreshold: Float = 0.02
    private var engineStartTime = Date.distantPast
    // 防止 complete(with:) 被多线程并发调用导致 Continuation 重复 resume
    private let finishLock = NSLock()

    /// 配置静音自动停止参数（由 AppCoordinator 在 start 之前调用）
    func configureAutoStop(enabled: Bool, timeout: TimeInterval, threshold: Float) {
        self.silenceAutoStopEnabled = enabled
        self.silenceTimeout = timeout
        self.silenceThreshold = threshold
    }

    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws {
        // 语音识别授权
        guard await ensureSpeechAuth() else { throw ASRError.speechNotAuthorized }

        // 麦克风授权（AVAudioEngine 输入依赖）
        guard await ensureMicAuth() else { throw ASRError.microphoneNotAuthorized }

        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError.speechNotAvailable(locale: locale.identifier)
        }
        self.recognizer = recognizer

        // 存储回调
        self.onAudioLevel = onAudioLevel
        self.onAutoStop = onAutoStop
        self.silenceStart = nil
        self.engineStartTime = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation  // 优化连续听写行为，降低延迟提高灵敏度
        // macOS 26 已统一本地/云端路由，原生格式直接喂即可，不需要 16kHz 重采样
        self.request = request

        finalText = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal { self?.finalText = text }
                onPartial(text)
            }
            if let _ = error {
                self?.complete(with: self?.finalText ?? "")
            } else if result?.isFinal == true {
                self?.complete(with: self?.finalText ?? "")
            }
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        // SFSpeechRecognizer 要求 16kHz 单声道（Code=203 "Corrupt" 否则）
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw ASRError.converterInit
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self, converter, targetFormat, hardwareFormat] buffer, _ in
            guard let self, let request = self.request else { return }
            let ratio = targetFormat.sampleRate / hardwareFormat.sampleRate
            let frameCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard frameCount > 0,
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
            let didProvide = ConverterFlag()
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                guard !didProvide.value else { status.pointee = .noDataNow; return nil }
                didProvide.value = true
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, outBuffer.frameLength > 0 else { return }

            // 计算 RMS 电平 + 静音检测
            let needsLevel = self.onAudioLevel != nil
            let needsSilence = self.silenceAutoStopEnabled && self.onAutoStop != nil
            if needsLevel || needsSilence {
                let chData = outBuffer.floatChannelData![0]
                let len = Int(outBuffer.frameLength)
                var sum: Float = 0
                for i in 0..<len { let s = chData[i]; sum += s * s }
                let rms = sqrt(sum / Float(len))
                if needsLevel { self.onAudioLevel?(rms) }
                if needsSilence {
                    // 启动后 1 秒内不触发静音检测，避免刚启动就被误判
                    let graceOk = Date().timeIntervalSince(self.engineStartTime) >= 1.0
                    if graceOk, rms < self.silenceThreshold {
                        if self.silenceStart == nil { self.silenceStart = Date() }
                        if let start = self.silenceStart,
                           Date().timeIntervalSince(start) >= self.silenceTimeout {
                            if self.onAutoStop?() == true { self.silenceStart = nil }
                        }
                    } else {
                        self.silenceStart = nil
                    }
                }
            }

            self.appendQueue.async { request.append(outBuffer) }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() async throws -> String {
        request?.endAudio()
        task?.finish()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        // 等待识别任务回传最终结果（最长 1.5s 兜底）
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            self.finishContinuation = cont
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.complete(with: self.finalText)
            }
        }
    }

    private func complete(with text: String) {
        finishLock.withLock {
            guard let c = finishContinuation else { return }
            finishContinuation = nil
            c.resume(returning: text)
        }
    }

    private func ensureSpeechAuth() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private func ensureMicAuth() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}
