import AppKit
#if !APP_STORE
import ApplicationServices
#endif

/// 粘贴服务：写剪贴板 + postToPid ⌘V。
/// macOS 26 上 postToPid 可靠；14 上可能被丢弃，此时文字在剪贴板中可手动粘贴。
@MainActor
final class PasteService {
    static let shared = PasteService()
    private let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    // 剪贴板保存/恢复
    private struct SavedClipboard {
        /// 用户原始剪贴板内容（写入我们的文字之前快照）。
        let items: [NSPasteboardItem]
        /// 写入我们文字之后的 changeCount；恢复前若它再变化，说明用户手动复制了新内容。
        let changeCountAfterWrite: Int
    }
    private var savedClipboard: SavedClipboard?
    private var restoreWork: DispatchWorkItem?

    func writeClipboardOnly(_ text: String) {
        writeClipboard(text)
    }

    @discardableResult
    func paste(_ text: String, to pid: pid_t) -> Bool {
        // ① 在碰剪贴板之前，先快照用户原始内容
        let savedItems = NSPasteboard.general.pasteboardItems ?? []
        // ② 写入我们的文字供 ⌘V 使用
        writeClipboard(text)
        // ③ 记录写入后的 changeCount，作为"用户是否又复制了新内容"的基准
        let countAfterWrite = NSPasteboard.general.changeCount
        savedClipboard = SavedClipboard(items: savedItems, changeCountAfterWrite: countAfterWrite)

        let sent = simulateCmdVviaPostToPid(pid: pid)
        Log.info("[Paste] postToPid ⌘V → pid=\(pid), sent=\(sent)")

        // 恢复策略：
        // - 发送成功 → 延迟 2s 恢复（给目标 app 处理粘贴的时间）
        // - 发送失败 → 不恢复，把文字留在剪贴板供用户手动 ⌘V
        //   （调用方会提示"文字已复制到剪贴板"）
        if sent {
            scheduleRestore(delay: 2.0)
        }
        return sent
    }

    // MARK: - 剪贴板保存与恢复

    /// 恢复剪贴板（如果用户在此期间没有手动复制新内容）。
    func restoreClipboard() {
        restoreWork?.cancel()
        restoreWork = nil
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let pb = NSPasteboard.general
        // changeCount 相对"我们写入后"又前进了 → 用户在此期间手动复制了内容，尊重它不覆盖
        guard pb.changeCount == saved.changeCountAfterWrite else {
            Log.info("[Paste] 剪贴板已被用户更新，跳过恢复")
            return
        }
        pb.clearContents()
        pb.writeObjects(saved.items)
        Log.info("[Paste] 剪贴板已恢复")
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

    // MARK: - 辅助功能（仅官网版）

#if !APP_STORE
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        openPane("Privacy_Accessibility")
    }
#endif

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
