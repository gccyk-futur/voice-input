import Foundation

/// 启动失败后，面板可以提供的恢复动作。
enum RecordingRecoveryAction: Equatable, Sendable {
    case retry
    case openInputSettings
    case openMicrophoneSettings
    case openSpeechSettings

    var title: String {
        switch self {
        case .retry: return VoiceKitLocalization.string("重新尝试")
        case .openInputSettings: return VoiceKitLocalization.string("打开声音设置…")
        case .openMicrophoneSettings: return VoiceKitLocalization.string("打开系统设置…")
        case .openSpeechSettings: return VoiceKitLocalization.string("打开系统设置…")
        }
    }
}

/// 面板向用户展示的启动失败语义。底层错误详情仍记录日志，不直接暴露给用户。
enum RecordingFailureKind: Equatable, Sendable {
    case audioInputUnavailable
    case noInputDevice
    case microphonePermission
    case speechPermission
    case speechUnavailable
    case serviceUnavailable
}

struct RecordingRecoveryNotice: Equatable, Sendable {
    let title: String
    let message: String
    let primaryAction: RecordingRecoveryAction
    let secondaryAction: RecordingRecoveryAction?

    static func forKind(_ kind: RecordingFailureKind) -> Self {
        switch kind {
        case .audioInputUnavailable:
            return Self(
                title: VoiceKitLocalization.string("麦克风暂时无法使用"),
                message: VoiceKitLocalization.string("已检测到麦克风，但当前无法开始采集声音。请重新连接耳机，或在声音设置中切换输入设备后重试。"),
                primaryAction: .retry,
                secondaryAction: .openInputSettings
            )
        case .noInputDevice:
            return Self(
                title: VoiceKitLocalization.string("无法开始听写"),
                message: VoiceKitLocalization.string("没有检测到可用的麦克风，请连接设备或在声音设置中选择输入设备。"),
                primaryAction: .retry,
                secondaryAction: .openInputSettings
            )
        case .microphonePermission:
            return Self(
                title: VoiceKitLocalization.string("需要麦克风权限"),
                message: VoiceKitLocalization.string("请允许 VoiceKit 使用麦克风后，再重新开始听写。"),
                primaryAction: .openMicrophoneSettings,
                secondaryAction: nil
            )
        case .speechPermission:
            return Self(
                title: VoiceKitLocalization.string("需要语音识别权限"),
                message: VoiceKitLocalization.string("请允许 VoiceKit 使用语音识别后，再重新开始听写。"),
                primaryAction: .openSpeechSettings,
                secondaryAction: nil
            )
        case .speechUnavailable:
            return Self(
                title: VoiceKitLocalization.string("无法开始听写"),
                message: VoiceKitLocalization.string("当前语言的系统语音识别不可用，请切换识别语言或语音引擎。"),
                primaryAction: .retry,
                secondaryAction: nil
            )
        case .serviceUnavailable:
            return Self(
                title: VoiceKitLocalization.string("无法开始听写"),
                message: VoiceKitLocalization.string("语音服务暂时不可用或启动较慢，请检查网络后重试。"),
                primaryAction: .retry,
                secondaryAction: nil
            )
        }
    }
}
