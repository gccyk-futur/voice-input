#if !APP_STORE

import AppKit
import ApplicationServices

/// 通过 Accessibility API 直接向目标 App 的焦点文本框插入文字。
///
/// 与 PasteService（剪贴板 + postToPid Cmd+V）不同，本实现：
/// - 不动剪贴板（无 save/restore 开销）
/// - 不模拟按键（无需焦点切换）
/// - 文字直接出现在目标 App 的输入框中
///
/// 仅官网分发版使用。App Store 版受 Guideline 2.4.5 限制，禁用此实现，
/// 统一走 PasteService 剪贴板方案。
@MainActor
final class AccessibilityPasteService {
    static let shared = AccessibilityPasteService()

    /// 检查辅助功能权限。
    ///
    /// AXIsProcessTrusted() 是 Accessibility API 官方提供的权限检查；
    /// CGEvent tap 属于另一套事件监听能力，不能用来推断 AXUIElement 是否可用。
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

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
            Log.info("[Paste] Accessibility 焦点元素角色: \(role)")
            let before = try getValue(focusedElement)
            guard let selectedRange = getSelectedTextRange(focusedElement),
                  let plan = TextInsertionPlan.make(
                    currentValue: before,
                    selectedRange: selectedRange,
                    insertion: text
                  ) else {
                Log.info("[Paste] Accessibility 元素没有可用文本值/选区，回退剪贴板方案")
                return false
            }

            var settable = DarwinBoolean(false)
            let settableResult = AXUIElementIsAttributeSettable(
                focusedElement,
                kAXValueAttribute as CFString,
                &settable
            )
            guard settableResult == .success, settable.boolValue else {
                Log.info("[Paste] Accessibility 元素角色 \(role) 的 value 不可写，回退剪贴板方案")
                return false
            }

            let result = AXUIElementSetAttributeValue(
                focusedElement,
                kAXValueAttribute as CFString,
                plan.replacement as CFTypeRef
            )
            guard result == .success else {
                Log.error("[Paste] Accessibility value 写入失败: \(result.rawValue)")
                return false
            }

            let after = try getValue(focusedElement)
            guard after == plan.replacement else {
                Log.error("[Paste] Accessibility value 写入验证失败，回退剪贴板方案")
                return false
            }

            // 恢复插入点是 best-effort；文本已经验证写入，不能因光标恢复失败
            // 再走一次剪贴板粘贴，否则会重复插入。
            if let rangeValue = makeTextRangeValue(location: plan.caretLocation),
               AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
               ) != .success {
                Log.info("[Paste] Accessibility 文本已写入，但插入点恢复失败")
            }

            Log.info("[Paste] Accessibility value 插入成功: \(text.count) 字符")
            return true
        } catch {
            Log.info("[Paste] Accessibility value 插入失败: \(error)")
            return false
        }
    }

    // MARK: - Private

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func getSelectedTextRange(_ element: AXUIElement) -> NSRange? {
        guard let rawValue = copyElementAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func makeTextRangeValue(location: Int) -> AXValue? {
        var range = CFRange(location: location, length: 0)
        return withUnsafeMutablePointer(to: &range) { pointer in
            AXValueCreate(.cfRange, pointer)
        }
    }

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

#endif
