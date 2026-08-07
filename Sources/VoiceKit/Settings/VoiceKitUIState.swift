import Foundation

enum VoiceKitTextScale: String, CaseIterable, Codable, Sendable {
    case system
    case large
    case extraLarge

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .large: return "较大"
        case .extraLarge: return "更大"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .system: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.30
        }
    }

    static func restored(from rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .system
    }
}

enum VoiceKitAppearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    static func restored(from rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .system
    }
}

enum VoiceKitDistribution: Equatable, Sendable {
    case direct
    case appStore
}

enum VoiceKitPermissionState: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case input
    case services
    case models
    case prompts
    case permissions
    case privacy
    case about

    var id: String { rawValue }

    var isSubpane: Bool {
        switch self {
        case .models, .prompts: return true
        default: return false
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    static func restored(from rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .general
    }

    var title: String {
        switch self {
        case .general: return "常规"
        case .input: return "语音引擎"
        case .services: return "AI 服务"
        case .models: return "模型管理"
        case .prompts: return "提示词管理"
        case .permissions: return "权限"
        case .privacy: return "数据隐私"
        case .about: return "关于"
        }
    }

    var description: String {
        switch self {
        case .general: return "快捷键、启动方式、声音和历史记录"
        case .input: return "选择语音引擎、语言和实时听写行为"
        case .services: return "了解 AI 润色如何工作，以及当前是否启用"
        case .models: return "管理云端 API 和本地模型"
        case .prompts: return "管理 AI 润色使用的系统提示词和用户模板"
        case .permissions: return "管理 VoiceKit 使用的系统权限"
        case .privacy: return "了解数据如何流转，以及 VoiceKit 不会做什么"
        case .about: return "版本、开源说明和联系方式"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .input: return "waveform"
        case .services: return "sparkles"
        case .models: return "cube"
        case .prompts: return "text.quote"
        case .permissions: return "hand.raised"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

enum VoiceKitPermissionReloadState: Equatable, Sendable {
    case hidden
    case recommended

    static func make(
        distribution: VoiceKitDistribution,
        permission: VoiceKitPermissionState,
        requested: Bool
    ) -> Self {
        guard distribution == .direct, permission == .granted, requested else {
            return .hidden
        }
        return .recommended
    }
}

struct WriteBackPresentation: Equatable, Sendable {
    let title: String
    let explanation: String
    let fallbackExplanation: String

    static func make(
        distribution: VoiceKitDistribution,
        permission: VoiceKitPermissionState
    ) -> Self {
        switch distribution {
        case .direct:
            switch permission {
            case .granted:
                return Self(
                    title: "辅助功能（直接写入）",
                    explanation: "已允许 VoiceKit 直接访问目标输入框写入文字。",
                    fallbackExplanation: "如果目标应用不支持直接写入，将回退到剪贴板和 ⌘V。"
                )
            case .notDetermined, .denied:
                return Self(
                    title: "辅助功能（直接写入）",
                    explanation: "允许 VoiceKit 直接访问目标输入框写入文字。",
                    fallbackExplanation: "未授权时，文字仍会保留在剪贴板，请手动按 ⌘V。"
                )
            }
        case .appStore:
            return Self(
                title: "自动写回（键盘事件）",
                explanation: "App Store 沙盒版会尝试自动写回识别结果；系统只保证发送尝试，不保证目标应用一定接受。",
                fallbackExplanation: "如果自动写回未生效，文字仍会保留在剪贴板，请手动按 ⌘V。"
            )
        }
    }
}
