import Foundation

/// 语音转文字引擎协议：所有 ASR 实现（系统/whisper/云端）遵循。
/// 不隔离到主线程——音频采集与语音分析必须在后台执行，否则会阻塞 UI。
/// 仅通过 onPartial 回调把结果抛回主线程（其内部需自行切回 MainActor）。
protocol ASREngine: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    /// DictationTranscriber 需要 app 在前台；SFSpeechRecognizer 不需要。
    var requiresForeground: Bool { get }

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
