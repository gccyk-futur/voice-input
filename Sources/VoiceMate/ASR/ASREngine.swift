import Foundation

/// 语音转文字引擎协议：所有 ASR 实现（系统/whisper/云端）遵循。
@MainActor
protocol ASREngine: AnyObject {
    /// 引擎标识："system" | "whisper" | "iflytek" | ...
    var id: String { get }
    var displayName: String { get }

    /// 开始识别，partials 为实时中间结果流（主线程回调）。
    func start(locale: Locale, onPartial: @escaping (String) -> Void) async throws
    /// 结束识别，返回最终文本。
    func stop() async throws -> String
}
