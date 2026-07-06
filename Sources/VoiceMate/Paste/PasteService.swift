import AppKit
import Carbon.HIToolbox

/// 粘贴服务：通过 CGEvent 模拟 Cmd+V 将文本填入当前光标位置。
/// 需要辅助功能权限；缺失时回退为写入剪贴板并由用户手动粘贴。
@MainActor
final class PasteService {
    static let shared = PasteService()

    private let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    /// 将文本写入剪贴板并模拟 Cmd+V。
    /// - Returns: true 表示已成功模拟粘贴；false 表示缺少辅助功能权限，仅写入剪贴板。
    @discardableResult
    func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted else {
            // 无辅助功能权限：已写入剪贴板，待用户手动 Cmd+V
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// 是否已授予辅助功能权限。
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 引导用户前往系统设置的辅助功能页。
    func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
