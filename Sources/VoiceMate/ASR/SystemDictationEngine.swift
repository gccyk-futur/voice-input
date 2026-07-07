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
        do {
            try audioEngine.start()
        } catch {
            // 启动失败：移除已安装的 tap、停掉引擎，避免下次 start 时
            // "input node already has a tap" 再次抛错造成反复崩溃。
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            throw error
        }

        finalText = ""
        // 基于时间轴的分段数组：每个 DictationTranscriber.Result 带 range: CMTimeRange，
        // 按 range.start 排序后维护有序分段。同一时间段内的修订版原地替换，避免停顿清空和重复追加。
        resultTask = Task.detached(priority: .userInitiated) {
            var segments: [Segment] = []
            var finalizedCount = 0
            do {
                for try await result in transcriber.results {
                    let t = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    let finalized = result.resultsFinalizationTime.isValid
                    let range = result.range

                    // 查找是否有与当前 range 重叠的已有分段
                    if let idx = segments.firstIndex(where: { Self.rangesOverlap($0.range, range) }) {
                        // 已有分段且已定稿、新结果未定稿 → 忽略（不降级）
                        if segments[idx].isFinalized && !finalized { continue }
                        let wasFinalized = segments[idx].isFinalized
                        segments[idx].text = t
                        segments[idx].range = range
                        segments[idx].isFinalized = finalized
                        if !wasFinalized && finalized {
                            finalizedCount += 1
                        }
                    } else {
                        // 新分段：找到正确的时间顺序插入位置
                        let insertAt = segments.firstIndex(where: {
                            CMTimeCompare(range.start, $0.range.start) < 0
                        }) ?? segments.count
                        segments.insert(Segment(range: range, text: t, isFinalized: finalized), at: insertAt)
                        if finalized { finalizedCount += 1 }
                    }

                    // 构建显示文本：已定稿分段（按时间序）+ 未定稿流式分段（按时间序）。
                    // 用 filter 而非 prefix(while:)，确保「较早段未定稿 + 较晚段已定稿」的中间态下，
                    // 已定稿分段仍被归入 committed（贴合 handoff §5 的语义）。
                    let committed = segments.filter { $0.isFinalized }.map(\.text)
                    let pending = segments.filter { !$0.isFinalized }.map(\.text)
                    let display = Self.buildDisplayText(committed: committed, pending: pending)
                    self.finalText = display
                    onPartial(display)
                }
            } catch {
                // 流结束或中止，忽略
            }
            print("[SystemDictation] result stream ended, segments=\(segments.count), finalized=\(finalizedCount)")
        }
    }

    /// 时间轴分段：每个分段对应 DictationTranscriber.Result 的一个时间区间。
    private struct Segment {
        var range: CMTimeRange
        var text: String
        var isFinalized: Bool
    }

    /// 判断两个 CMTimeRange 是否有重叠（含包含关系）。
    private static func rangesOverlap(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool {
        let aEnd = CMTimeRangeGetEnd(a)
        let bEnd = CMTimeRangeGetEnd(b)
        return CMTimeCompare(a.start, bEnd) < 0 && CMTimeCompare(b.start, aEnd) < 0
    }

    /// 将已定稿和流式分段的文本拼接为显示文本。
    /// 拉丁字母/数字之间补空格，CJK 等直接相连。
    private static func buildDisplayText(committed: [String], pending: [String]) -> String {
        let all = committed + pending
        return all.reduce(into: "") { acc, next in
            if acc.isEmpty || next.isEmpty {
                acc += next
                return
            }
            let last = acc.unicodeScalars.last!
            let first = next.unicodeScalars.first!
            let needsSpace = isLatinLetterOrDigit(last) && isLatinLetterOrDigit(first)
            if needsSpace { acc += " " }
            acc += next
        }
    }

    private static func isLatinLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
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
