import AppKit

extension VoiceKitAppearance {
    /// AppKit 窗口级外观。返回 nil 表示跟随系统——窗口会在系统切换深浅色时自动跟随，
    /// 无需 app 做任何事。这比 SwiftUI 的 preferredColorScheme 可靠：后者对
    /// NavigationSplitView detail / NSPanel 内容树的传播在 macOS 上存在缺陷
    /// （从深色切回跟随系统或切换覆盖值时，内容区残留旧外观）。
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// 当前持久化的外观设置
    static var current: VoiceKitAppearance {
        .restored(from: UserDefaults.standard.string(forKey: "voicekit.ui.appearance") ?? "")
    }
}

/// 把「外观」设置应用到指定窗口，并跟随设置变化持续更新。
/// 由窗口控制器持有，生命周期与窗口一致。
@MainActor
final class AppearanceApplier {
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
        apply()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
    }

    private func apply() {
        window?.appearance = VoiceKitAppearance.current.nsAppearance
    }

    // 不主动移除 observer：闭包弱引用 self，窗口释放后回调为空操作；
    // 窗口控制器本身是单例复用，observer 数量恒定（每类窗口一个）。
}
