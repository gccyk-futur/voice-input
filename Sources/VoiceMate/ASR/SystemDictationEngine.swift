import Foundation
import AVFoundation
import Speech
import CoreMedia

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
        // DictationTranscriber.Result 的 text 只是「当前这一句(phrase)」的文本、并非累计全文，
        // 且同一句会被反复修订（流式 → 定稿，甚至定稿后还会出修正版）。因此按 result.range
        // （时间区间）累积分句：同一区间的不同修订版原地替换，避免重复追加或停顿清空。
        resultTask = Task.detached(priority: .userInitiated) { [inputBuilder] in
            var transcript = ""
            var current = ""
            var lastCommitted = ""
            var lastAppended = ""
            func appendCommitted(_ t: String) {
                if !lastAppended.isEmpty, transcript.hasSuffix(lastAppended) {
                    transcript.removeSubrange(transcript.index(transcript.endIndex, offsetBy: -lastAppended.count)..<transcript.endIndex)
                }
                let sep = (transcript.isEmpty || t.isEmpty) ? "" :
                    (Self.isLatinLetterOrDigit(transcript.unicodeScalars.last!) && Self.isLatinLetterOrDigit(t.unicodeScalars.first!) ? " " : "")
                let added = sep + t
                transcript += added
                lastAppended = added
            }
            do {
                for try await result in transcriber.results {
                    let t = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    let finalized = result.resultsFinalizationTime.isValid
                    if current.isEmpty, !lastCommitted.isEmpty,
                       t == lastCommitted || t.hasPrefix(lastCommitted) || lastCommitted.hasPrefix(t) {
                        continue
                    }
                    if finalized {
                        appendCommitted(t)
                        lastCommitted = t
                        current = ""
                    } else if !current.isEmpty, !Self.isRefinement(current, t) {
                        appendCommitted(current)
                        lastCommitted = current
                        current = t
                    } else {
                        current = t
                    }
                    let display = current.isEmpty ? transcript : Self.join(transcript, current)
                    self.finalText = display
                    onPartial(display)
                }
            } catch {
                // 流结束或中止，忽略
            }
        }
    }

    /// 拼接两个文本片段：拉丁字母/数字之间补一个空格，CJK 等则直接相连（避免中文里出现多余空格）。
    private static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        let aLast = a.unicodeScalars.last!
        let bFirst = b.unicodeScalars.first!
        let needsSpace = isLatinLetterOrDigit(aLast) && isLatinLetterOrDigit(bFirst)
        return needsSpace ? a + " " + b : a + b
    }

    private static func isLatinLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    /// 判断 next 是否为 prev 的同一句的精炼版（前缀包含关系），用于区分「同一句持续改进」与「开始了新的一句」。
    private static func isRefinement(_ prev: String, _ next: String) -> Bool {
        next == prev || next.hasPrefix(prev) || prev.hasPrefix(next)
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
