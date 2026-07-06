import Foundation

/// 语音转文字引擎协议：所有 ASR 实现（系统/whisper/云端）遵循。
/// 不隔离到主线程——音频采集与语音分析必须在后台执行，否则会阻塞 UI。
/// 仅通过 onPartial 回调把结果抛回主线程（其内部需自行切回 MainActor）。
protocol ASREngine: AnyObject, Sendable {
    /// 引擎标识："system" | "whisper" | "iflytek" | ...
    var id: String { get }
    var displayName: String { get }

    /// 开始识别，partials 为实时中间结果流（后台线程回调，需自行切回主线程更新 UI）。
    func start(locale: Locale, onPartial: @escaping @Sendable (String) -> Void) async throws
    /// 结束识别，返回最终文本。
    func stop() async throws -> String
}
