import Foundation
import AVFoundation
import Speech

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

    func start(locale: Locale, onPartial: @escaping @Sendable (String) -> Void) async throws {
        // 语音识别授权
        guard await ensureSpeechAuth() else { throw ASRError.speechNotAuthorized }

        // 麦克风授权（AVAudioEngine 输入依赖）
        guard await ensureMicAuth() else { throw ASRError.microphoneNotAuthorized }

        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError.speechNotAvailable(locale: locale.identifier)
        }
        self.recognizer = recognizer

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
            var didProvide = false
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                guard !didProvide else { status.pointee = .noDataNow; return nil }
                didProvide = true
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, outBuffer.frameLength > 0 else { return }
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
        guard let c = finishContinuation else { return }
        finishContinuation = nil
        c.resume(returning: text)
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
