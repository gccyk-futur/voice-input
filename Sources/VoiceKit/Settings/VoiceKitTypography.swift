import SwiftUI

struct VoiceKitTypography {
    let scale: VoiceKitTextScale

    private var multiplier: CGFloat { scale.multiplier }
    private var followsSystem: Bool { scale == .system }

    /// 默认档位使用 SwiftUI 语义字体，保持 macOS 的系统字体层级；
    /// macOS 不提供 iOS 那种全局 Dynamic Type，因此手动档位使用固定比例，
    /// 并由设置页把所有正文、说明和控件统一接入这套令牌。
    var title: Font {
        followsSystem ? .title2 : .system(size: 22 * multiplier, weight: .bold)
    }

    var sectionTitle: Font {
        followsSystem ? .headline : .system(size: 16 * multiplier, weight: .semibold)
    }

    var body: Font {
        followsSystem ? .body : .system(size: 13 * multiplier)
    }

    var callout: Font {
        followsSystem ? .callout : .system(size: 12 * multiplier)
    }

    var secondary: Font {
        followsSystem ? .subheadline : .system(size: 11 * multiplier)
    }

    var metadata: Font {
        followsSystem ? .caption : .system(size: 10 * multiplier)
    }
}

extension VoiceKitAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct VoiceKitTextScaleKey: EnvironmentKey {
    static let defaultValue = VoiceKitTextScale.system
}

extension EnvironmentValues {
    var voiceKitTextScale: VoiceKitTextScale {
        get { self[VoiceKitTextScaleKey.self] }
        set { self[VoiceKitTextScaleKey.self] = newValue }
    }
}

extension View {
    func voiceKitTextScale(_ scale: VoiceKitTextScale) -> some View {
        environment(\.voiceKitTextScale, scale)
    }
}
