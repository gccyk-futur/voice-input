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

    private let audioEngine = AVAudioEngine()
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
        // 中文等走服务器识别（requiresOnDeviceRecognition 默认 false 即可）
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
        // SFSpeechRecognizer 对 16kHz 单声道最稳；Mac 硬件输入多为 44.1kHz 立体声，
        // 直接 append 会让服务器收到损坏音频（kAFAssistantErrorDomain Code=203 "Corrupt"）。
        // 因此在 tap 内先转成 16kHz 单声道再喂入。
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw ASRError.converterInit
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self, converter, targetFormat, hardwareFormat] buffer, _ in
            guard let request = self?.request else { return }
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
            request.append(outBuffer)
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
