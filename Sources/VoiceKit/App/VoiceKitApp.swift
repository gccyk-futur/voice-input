import SwiftUI

/// 菜单栏图标由 AppDelegate 通过 NSStatusItem + NSPopover 原生管理，
/// 不使用 SwiftUI 的 MenuBarExtra（避免图标静默消失后无法自愈）。
@main
struct VoiceKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
