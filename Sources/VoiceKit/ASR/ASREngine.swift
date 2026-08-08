import Foundation

/// 语音转文字引擎协议：所有 ASR 实现（系统/whisper/云端）遵循。
/// 不隔离到主线程——音频采集与语音分析必须在后台执行，否则会阻塞 UI。
/// 仅通过 onPartial 回调把结果抛回主线程（其内部需自行切回 MainActor）。
protocol ASREngine: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    /// DictationTranscriber 需要 app 在前台；SFSpeechRecognizer 不需要。
    var requiresForeground: Bool { get }

    /// 录音过程中发生的运行时错误（设备断开、云端连接中断等）。
    /// start() 抛出的是"起飞失败"；本回调覆盖"飞行中失败"。由 coordinator 设置，
    /// 触发后应把会话退回 idle 并提示用户。
    var onFailure: (@Sendable (Error) -> Void)? { get set }

    /// 开始识别。
    /// - Parameters:
    ///   - onPartial: 实时中间结果回调
    ///   - onAudioLevel: 音频电平回调（0.0~1.0），用于驱动波形；不需要可传 nil
    ///   - onAutoStop: 静音超时自动结束回调；不需要可传 nil。返回 true 表示已处理
    func start(locale: Locale,
               onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: (@Sendable (Float) -> Void)?,
               onAutoStop: (@Sendable () -> Bool)?) async throws
    func stop() async throws -> String
}

/// ASR 相关错误：引擎启动/运行失败的统一错误类型。
enum ASRError: LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized
    /// 系统没有可用的音频输入设备（如 Mac mini 未接麦克风，且无默认输入设备）。
    case noInputDevice
    case noAudioFormat
    case converterInit
    /// AVAudioEngine 安装 tap / 启动失败，带底层原因（常来自 NSException 桥接）。
    case audioEngineStartFailed(String)
    case noSpeechAsset(original: String)
    case speechNotAvailable(locale: String)

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return VoiceKitLocalization.string("未授权语音识别，请在系统设置→隐私与安全性→语音识别 中允许")
        case .microphoneNotAuthorized:
            return VoiceKitLocalization.string("未授权麦克风，请在系统设置→隐私与安全性→麦克风 中允许")
        case .noInputDevice:
            return VoiceKitLocalization.string("未检测到麦克风，请连接麦克风或在系统设置→声音→输入中选择一个输入设备")
        case .noAudioFormat:
            return VoiceKitLocalization.string("无可用的音频格式")
        case .converterInit:
            return VoiceKitLocalization.string("音频转换器初始化失败，请检查麦克风的采样率设置或尝试更换输入设备")
        case .audioEngineStartFailed(let reason):
            return VoiceKitLocalization.format("音频引擎启动失败：%@", reason)
        case .noSpeechAsset(let original):
            return VoiceKitLocalization.format("所选语言（%@）无可用语音识别模型，请在设置中将识别语言改为 zh-Hans / zh-Hant 等受支持的区域码", original)
        case .speechNotAvailable(let locale):
            return VoiceKitLocalization.format("当前设备不支持语言（%@）的语音识别", locale)
        }
    }
}
