import AppKit
import ApplicationServices

/// 粘贴服务：写剪贴板 + postToPid ⌘V。
/// macOS 26 上 postToPid 可靠；14 上可能被丢弃，此时文字在剪贴板中可手动粘贴。
@MainActor
final class PasteService {
    static let shared = PasteService()
    private let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    // 剪贴板保存/恢复
    private struct SavedClipboard {
        let changeCount: Int
        let items: [NSPasteboardItem]
    }
    private var savedClipboard: SavedClipboard?
    private var restoreWork: DispatchWorkItem?

    func writeClipboardOnly(_ text: String) {
        writeClipboard(text)
    }

    @discardableResult
    func paste(_ text: String, to pid: pid_t) -> Bool {
        // 保存当前剪贴板，以备恢复
        saveCurrentClipboard()
        writeClipboard(text)
        let sent = simulateCmdVviaPostToPid(pid: pid)
        print("[Paste] postToPid ⌘V → pid=\(pid), isTrusted=\(isTrusted), sent=\(sent)")

        // 恢复策略：
        // - 发送失败 → 立即恢复
        // - 发送成功 → 延迟 2s 恢复（给目标 app 处理粘贴的时间）
        if sent {
            scheduleRestore(delay: 2.0)
        } else {
            restoreClipboard()
        }
        return sent
    }

    // MARK: - 剪贴板保存与恢复

    /// 保存当前剪贴板全部 item（含 changeCount 用于后续判断用户是否有新复制行为）。
    private func saveCurrentClipboard() {
        let pb = NSPasteboard.general
        let items = pb.pasteboardItems ?? []
        savedClipboard = SavedClipboard(changeCount: pb.changeCount, items: items)
    }

    /// 恢复剪贴板（如果用户在此期间没有手动复制新内容）。
    func restoreClipboard() {
        restoreWork?.cancel()
        restoreWork = nil
        guard let saved = savedClipboard else { return }
        let pb = NSPasteboard.general
        // 用户在此期间手动复制了内容 → 不恢复，尊重用户操作
        guard pb.changeCount == saved.changeCount else {
            print("[Paste] 剪贴板已被用户更新，跳过恢复")
            savedClipboard = nil
            return
        }
        pb.clearContents()
        pb.writeObjects(saved.items)
        savedClipboard = nil
        print("[Paste] 剪贴板已恢复")
    }

    /// 延迟恢复（避免过早恢复导致目标 app 粘贴失败）。
    private func scheduleRestore(delay: TimeInterval) {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.restoreClipboard()
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 剪贴板写入

    private func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Cmd+V 模拟

    /// 返回 true 表示事件已创建并投递。
    @discardableResult
    private func simulateCmdVviaPostToPid(pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            print("[Paste] CGEvent 创建失败")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        usleep(10_000)
        up.postToPid(pid)
        return true
    }

    // MARK: - 辅助功能

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        openPane("Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openPane("Privacy_Microphone")
    }

    func openSpeechSettings() {
        openPane("Privacy_SpeechRecognition")
    }

    private func openPane(_ anchor: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
