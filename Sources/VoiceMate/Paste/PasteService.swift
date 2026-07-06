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

    /// 仅写剪贴板，不尝试粘贴。用于无目标 app 的场景。
    func writeClipboardOnly(_ text: String) {
        writeClipboard(text)
    }

    /// 将文本插入到当前光标位置（HID 级别事件）。
    /// - Returns: true 表示已成功插入；false 表示未授权辅助功能，仅写入剪贴板（需手动 Cmd+V）。
    @discardableResult
    func paste(_ text: String) -> Bool {
        if isTrusted, insertViaAccessibility(text) {
            return true
        }
        writeClipboard(text)
        return simulateCmdV()
    }

    /// 将文本插入到指定进程的光标位置。优先 AX，回退写剪贴板 + ⌘V 直送目标 PID。
    /// 直送 PID 比 HID 投递更可靠——无需目标 app 在前台。
    @discardableResult
    func paste(_ text: String, to pid: pid_t) -> Bool {
        if isTrusted, insertViaAccessibility(text) {
            return true
        }
        writeClipboard(text)
        return simulateCmdV(to: pid)
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

    /// 通过 HID 事件 + postToPid 双通道模拟 ⌘V，最大化粘贴成功率。
    private func simulateCmdV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // 主通道：HID 级别投递，走完整系统事件链（WindowServer → target run loop → 响应链）
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
        // 辅通道：PID 直送，以防 HID 投递在 agent app 上下文中被限制
        usleep(5_000)
        down.postToPid(pid)
        usleep(10_000)
        up.postToPid(pid)
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
