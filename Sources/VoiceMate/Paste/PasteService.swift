import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 粘贴服务：将文本写入当前光标所在的输入框。
///
/// 优先用辅助功能 API（AX）直接往「系统当前焦点元素」插入文本——这种方式不依赖本 app
/// 是否抢到焦点、也不依赖剪贴板，且是光标处插入（不会替换已有内容）。
/// 仅当未授权辅助功能时才回退为：写入剪贴板 + 模拟 Cmd+V（此时需目标 app 在前台）。
@MainActor
final class PasteService {
    static let shared = PasteService()
    private let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    /// 将文本插入到当前光标位置。
    /// - Returns: true 表示已成功插入；false 表示未授权辅助功能，仅写入剪贴板（需手动 Cmd+V）。
    @discardableResult
    func paste(_ text: String) -> Bool {
        // 优先：辅助功能直接插入（光标处，不替换已有文本）。需授权且当前目标 app 支持。
        if isTrusted, insertViaAccessibility(text) {
            return true
        }
        // 回退：写入剪贴板 + 模拟 ⌘V。⌘V 是普通按键，**不需要**辅助功能授权，
        // 因此无论 isTrusted 与否都执行——否则剪贴板有字却粘不出来。
        writeClipboard(text)
        return simulateCmdV()
    }

    /// 通过系统辅助功能，把文本插入到当前激活 app 的焦点文本元素的光标处。
    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let attrFocused = kAXFocusedUIElementAttribute as CFString
        guard AXUIElementCopyAttributeValue(systemWide, attrFocused, &focused) == .success,
              let elemRef = focused else { return false }
        let elem = elemRef as! AXUIElement
        let cf = text as CFString
        // 设置选区文本 = 在光标处插入（若有选区则替换选区，符合预期）；不会清空整篇内容。
        return AXUIElementSetAttributeValue(elem, kAXSelectedTextAttribute as CFString, cf) == .success
    }

    private func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func simulateCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
