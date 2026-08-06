import Foundation

/// postToPid 使用的、在 macOS 14+ 已验证可用的 ⌘V 事件序列。
///
/// 这里刻意只投递 V down/up，并在两个 V 事件上设置 `.maskCommand`。
/// 额外合成 Command down/up 会改变目标进程的修饰键状态，导致粘贴失效或
/// 后续键盘输入被锁住；兼容性基线因此不是“看起来更完整”的四事件序列。
struct CmdVEventPlan: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case vDown
        case vUp
    }

    let events: [Event]

    init() {
        events = [.vDown, .vUp]
    }

    var isBalanced: Bool {
        var vPressed = false

        for event in events {
            switch event {
            case .vDown:
                guard !vPressed else { return false }
                vPressed = true
            case .vUp:
                guard vPressed else { return false }
                vPressed = false
            }
        }

        return !vPressed
    }
}
