import Foundation
@preconcurrency import Speech
@preconcurrency import AVFAudio

/// 留档补识别：对历史留档（.m4a）用「当时使用的引擎」再识别一次。
///
/// 定位是网络重试式的补救：ASR 显示已连接却不出字时，用同一引擎对同一段录音
/// 重跑一次——补得出来是当时链路丢了，补不出来也能排除引擎差异的干扰。
/// 系统听写（含 legacy）走本机 SFSpeechURLRecognitionRequest；
/// 讯飞/阿里云把留档解码成 16k PCM 后全速灌入一条新会话（服务端断句与实时收听
/// 可能有轻微差异，速度优先）；
/// Deepgram 用其预录音 REST API。
enum AudioRetranscriber {

    enum RetranscribeError: LocalizedError {
        case recognizerUnavailable
        case notAuthorized
        case emptyResult
        case timeout
        case credentialsMissing(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return VoiceKitLocalization.string("本机语音识别当前不可用，请稍后再试")
            case .notAuthorized:
                return VoiceKitLocalization.string("未授权语音识别，请在系统设置→隐私与安全性→语音识别 中允许")
            case .emptyResult:
                return VoiceKitLocalization.string("没有识别出内容——录音本身可能是静音或音量过低")
            case .timeout:
                return VoiceKitLocalization.string("识别超时，请稍后再试")
            case .credentialsMissing(let engineName):
                return VoiceKitLocalization.format("「%@」的凭据未配置，无法用它重新识别", engineName)
            case .failed(let reason):
                return VoiceKitLocalization.format("识别失败：%@", reason)
            }
        }
    }

    /// 按条目当时使用的引擎对留档补识别，返回最终文本。
    /// - Parameters:
    ///   - engine: HistoryItem.engine（system / system-legacy / aliyun / xunfei / deepgram）
    ///   - languageID: 识别语言（跟随当前 ASR 语言设置，如 zh-Hans-CN）。
    static func transcribe(url: URL, engine: String, languageID: String) async throws -> String {
        let asr = await MainActor.run { ConfigStore.shared.config.asr }
        let locale = Locale(identifier: languageID)
        switch engine {
        case "xunfei":
            let cfg = asr.xunfei
            guard !cfg.appId.trimmingCharacters(in: .whitespaces).isEmpty,
                  !cfg.apiKey.trimmingCharacters(in: .whitespaces).isEmpty,
                  !cfg.apiSecret.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw RetranscribeError.credentialsMissing(VoiceKitLocalization.string("讯飞听写"))
            }
            let pcm = try decodeToPCM16(url: url)
            let engine = XunfeiASREngine(
                appId: cfg.appId, apiKey: cfg.apiKey, apiSecret: cfg.apiSecret,
                dynamicCorrection: cfg.dynamicCorrection,
                autoStopEnabled: false
            )
            let text = try await engine.transcribePCM(pcm, locale: locale)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RetranscribeError.emptyResult
            }
            return text
        case "aliyun":
            let cfg = asr.aliyun
            guard !cfg.apiKey.trimmingCharacters(in: .whitespaces).isEmpty,
                  !cfg.workspaceId.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw RetranscribeError.credentialsMissing(VoiceKitLocalization.string("阿里云 Fun-ASR"))
            }
            let pcm = try decodeToPCM16(url: url)
            let engine = AlibabaASREngine(
                apiKey: cfg.apiKey, workspaceId: cfg.workspaceId, region: cfg.region, model: cfg.model,
                semanticPunctuation: cfg.semanticPunctuation,
                speechNoiseThreshold: cfg.speechNoiseThreshold,
                maxSentenceSilence: cfg.maxSentenceSilence,
                autoStopEnabled: false
            )
            let text = try await engine.transcribePCM(pcm, locale: locale)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RetranscribeError.emptyResult
            }
            return text
        case "deepgram":
            let cfg = asr.deepgram
            let key = cfg.apiKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw RetranscribeError.credentialsMissing("Deepgram")
            }
            return try await transcribeDeepgram(url: url, apiKey: key, model: cfg.model, languageID: languageID)
        default:
            // system / system-legacy / 未知引擎：本机离线识别
            return try await transcribeOnDevice(url: url, languageID: languageID)
        }
    }

    // MARK: - 留档 → 16k mono int16 PCM

    /// 把 .m4a 整段解码并重采样为讯飞/阿里云会话要求的 PCM 格式。
    static func decodeToPCM16(url: URL) throws -> Data {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw RetranscribeError.failed(error.localizedDescription)
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw RetranscribeError.failed("AVAudioConverter")
        }
        let srcCapacity = AVAudioFrameCount(max(file.length, 1))
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcCapacity) else {
            throw RetranscribeError.failed("AVAudioPCMBuffer")
        }
        do {
            try file.read(into: srcBuffer)
        } catch {
            throw RetranscribeError.failed(error.localizedDescription)
        }
        let ratio = 16000.0 / file.processingFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio) + 1024
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: dstCapacity) else {
            throw RetranscribeError.failed("AVAudioPCMBuffer")
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: dstBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return srcBuffer
        }
        if let conversionError {
            throw RetranscribeError.failed(conversionError.localizedDescription)
        }
        guard dstBuffer.frameLength > 0, let ch = dstBuffer.int16ChannelData?.pointee else {
            throw RetranscribeError.emptyResult
        }
        return Data(bytes: ch, count: Int(dstBuffer.frameLength) * 2)
    }

    // MARK: - Deepgram 预录音 REST

    private static func transcribeDeepgram(url: URL, apiKey: String, model: String, languageID: String) async throws -> String {
        let language = Locale(identifier: languageID).language.languageCode?.identifier ?? "zh"
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language)
        ]
        guard let endpoint = components.url else {
            throw RetranscribeError.failed("Deepgram URL")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try Data(contentsOf: url)
        } catch {
            throw RetranscribeError.failed(error.localizedDescription)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RetranscribeError.failed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RetranscribeError.failed("Deepgram HTTP \(http.statusCode): \(body.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else {
            throw RetranscribeError.failed("Deepgram response")
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RetranscribeError.emptyResult }
        return text
    }

    // MARK: - 本机识别（系统听写条目）

    /// 对音频文件做整段识别，返回最终文本。
    static func transcribeOnDevice(url: URL, languageID: String) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw RetranscribeError.notAuthorized
        }
        // 优先本机识别（requiresOnDeviceRecognition 之前先问 supportsOnDeviceRecognition）
        let locale = Locale(identifier: languageID)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw RetranscribeError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // 本机模型可用时强制本机：离线补识别不该依赖网络；
        // 不可用则交给系统默认路由（可能走 Apple 服务器，与实时听写一致）。
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let lock = NSLock()
            let resumeOnce: (Result<String, Error>) -> Void = { result in
                lock.withLock {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(with: result)
                }
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(.failure(RetranscribeError.failed(error.localizedDescription)))
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    resumeOnce(.failure(RetranscribeError.emptyResult))
                } else {
                    resumeOnce(.success(text))
                }
            }

            // 整段文件识别偶尔迟迟不返回 final（长静音结尾等）：
            // 超时后取已有最优结果，拿不到再按超时失败处理。
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                task.cancel()
                resumeOnce(.failure(RetranscribeError.timeout))
            }
        }
    }
}
