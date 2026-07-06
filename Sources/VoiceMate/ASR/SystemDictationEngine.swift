import Foundation
import AVFoundation
import Speech

/// 系统听写引擎：基于 macOS 26 的 SpeechAnalyzer + SpeechTranscriber（实时渐进转写）。
/// 部署目标即 macOS 26，故默认走 SpeechAnalyzer；如后续需支持更低版本可在此追加 SFSpeechRecognizer 降级分支。
@MainActor
final class SystemDictationEngine: ASREngine {
    let id = "system"
    let displayName = "系统听写"

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var finalText: String = ""

    func start(locale: Locale, onPartial: @escaping (String) -> Void) async throws {
        // 语音识别授权
        let auth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard auth == .authorized else { throw ASRError.speechNotAuthorized }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ASRError.noAudioFormat
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
        resultTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self.finalText = text
                    }
                    guard !text.isEmpty else { continue }
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

enum ASRError: Error {
    case speechNotAuthorized
    case noAudioFormat
    case converterInit
}
