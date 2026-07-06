import Foundation
import AVFoundation
import Speech

/// 系统听写引擎：基于 macOS 26 的 SpeechAnalyzer + DictationTranscriber（实时渐进连续听写）。
/// 选用 DictationTranscriber 而非 SpeechTranscriber，是因为前者使用系统「连续听写」的
/// 本地模型（用户已确认本机可用），而 SpeechTranscriber 的中文短句资产经常缺失。
///
/// 注意：本类**不隔离到主线程**。音频采集、语音模型加载与转写分析都在调用方提供的
/// 后台 Task 中执行，避免阻塞 UI 主线程（否则表现为菜单栏转圈、整 app 卡死）。
/// 仅通过 onPartial 把识别结果抛回上层，由上层负责切回 MainActor 刷新界面。
final class SystemDictationEngine: ASREngine, @unchecked Sendable {
    let id = "system"
    let displayName = "系统听写"

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var finalText: String = ""

    func start(locale: Locale, onPartial: @escaping @Sendable (String) -> Void) async throws {
        // 语音识别授权
        let speechOK: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechOK = true
        case .notDetermined:
            speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default:
            speechOK = false
        }
        guard speechOK else { throw ASRError.speechNotAuthorized }

        // 麦克风授权（macOS TCC：AVAudioEngine 输入依赖麦克风权限，不显式请求可能收到静音且不报错）
        let micOK: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micOK = true
        case .notDetermined:
            micOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default:
            micOK = false
        }
        guard micOK else { throw ASRError.microphoneNotAuthorized }

        // 解析为本机实际支持的听写语言。DictationTranscriber 使用系统连续听写的本地模型，
        // supportedLocale(equivalentTo:) 会把 "zh-CN" 解析成机器上真实存在的模型语言；
        // 直接传 zh-CN 可能被解析成 cmn 而无资产。解析不到则回退到其他引擎。
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ASRError.noSpeechAsset(original: locale.identifier)
        }
        let transcriber = DictationTranscriber(locale: resolved, preset: .progressiveLongDictation)
        self.transcriber = transcriber

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ASRError.noSpeechAsset(original: locale.identifier)
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder
        let analyzer = SpeechAnalyzer(inputSequence: inputSequence, modules: [transcriber])
        self.analyzer = analyzer

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
            throw ASRError.converterInit
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [converter, analyzerFormat, hardwareFormat, inputBuilder] buffer, _ in
            let ratio = analyzerFormat.sampleRate / hardwareFormat.sampleRate
            let frameCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard frameCount > 0,
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: frameCount) else { return }
            var didProvide = false
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                guard !didProvide else { status.pointee = .noDataNow; return nil }
                didProvide = true
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, outBuffer.frameLength > 0 else { return }
            inputBuilder.yield(AnalyzerInput(buffer: outBuffer))
        }

        audioEngine.prepare()
        try audioEngine.start()

        finalText = ""
        resultTask = Task.detached(priority: .userInitiated) { [inputBuilder] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    // DictationTranscriber.Result 无 isFinal 字段，始终以最新非空文本作为最终结果
                    self.finalText = text
                    onPartial(text)
                }
            } catch {
                // 流结束或中止，忽略
            }
        }
    }

    func stop() async throws -> String {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputBuilder?.finish()
        inputBuilder = nil
        resultTask?.cancel()
        resultTask = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
        return finalText
    }
}

enum ASRError: LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized
    case noAudioFormat
    case converterInit
    case noSpeechAsset(original: String)
    case speechNotAvailable(locale: String)

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: return "未授权语音识别，请在系统设置→隐私与安全性→语音识别 中允许"
        case .microphoneNotAuthorized: return "未授权麦克风，请在系统设置→隐私与安全性→麦克风 中允许"
        case .noAudioFormat: return "无可用的音频格式"
        case .converterInit: return "音频转换器初始化失败"
        case .noSpeechAsset(let original): return "所选语言（\(original)）无可用语音识别模型，请在设置中将识别语言改为 zh-Hans / zh-Hant 等受支持的区域码"
        case .speechNotAvailable(let locale): return "当前设备不支持语言（\(locale)）的语音识别"
        }
    }
}
