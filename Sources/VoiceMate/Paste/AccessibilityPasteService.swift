import AppKit
import ApplicationServices

/// 通过 Accessibility API 直接向目标 App 的焦点文本框插入文字。
///
/// 与 PasteService（剪贴板 + postToPid Cmd+V）不同，本实现：
/// - 不动剪贴板（无 save/restore 开销）
/// - 不模拟按键（无需焦点切换）
/// - 文字直接出现在目标 App 的输入框中
///
/// 这是 Superwhisper、MacWhisper、Wispr Flow 等头部听写 App 的标准做法。
@MainActor
final class AccessibilityPasteService {
    static let shared = AccessibilityPasteService()

    private let textElementRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
    ]

    /// 检查辅助功能权限
    var isTrusted: Bool { AXIsProcessTrusted() }

    func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 向当前系统焦点元素插入文字。
    /// - Returns: 成功返回 true；失败（权限、无焦点元素、元素不支持等）返回 false
    func insertText(_ text: String) -> Bool {
        guard isTrusted else {
            print("[AccessibilityPaste] 辅助功能权限未授权")
            return false
        }
        guard !text.isEmpty else { return false }

        do {
            let focusedElement = try getFocusedElement()
            let role = try getRole(focusedElement)
            print("[AccessibilityPaste] 焦点元素角色: \(role)")

            guard textElementRoles.contains(role) else {
                print("[AccessibilityPaste] 不支持的焦点元素角色: \(role)，回退剪贴板方案")
                return false
            }

            // 读取当前值（用于验证写入是否成功）
            let before = (try? getValue(focusedElement)) ?? ""

            let result = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            guard result == .success else {
                print("[AccessibilityPaste] AXUIElementSetAttributeValue 失败: \(result.rawValue)")
                return false
            }

            // 验证写入：部分 App（如某些 Electron 应用）静默失败
            let after = (try? getValue(focusedElement)) ?? ""
            if before == after, !before.isEmpty {
                print("[AccessibilityPaste] 写入验证失败（值未变化），回退剪贴板方案")
                return false
            }

            print("[AccessibilityPaste] 成功插入 \(text.count) 字符")
            return true
        } catch {
            print("[AccessibilityPaste] 插入失败: \(error)")
            return false
        }
    }

    // MARK: - Private

    private func getFocusedElement() throws -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused as! AXUIElement? else {
            throw AccessibilityPasteError.noFocusedElement
        }
        return element
    }

    private func getRole(_ element: AXUIElement) throws -> String {
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard err == .success, let roleStr = role as? String else {
            throw AccessibilityPasteError.generalFailure
        }
        return roleStr
    }

    private func getValue(_ element: AXUIElement) throws -> String {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let str = value as? String else {
            throw AccessibilityPasteError.generalFailure
        }
        return str
    }
}

enum AccessibilityPasteError: LocalizedError {
    case noFocusedElement
    case generalFailure

    var errorDescription: String? {
        switch self {
        case .noFocusedElement: return "未找到焦点元素"
        case .generalFailure: return "Accessibility API 调用失败"
        }
    }
}
