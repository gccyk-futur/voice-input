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

    /// 只写剪贴板（无目标 App / 仅复制场景）：写入后仍延迟还原，
    /// 保证"临时用一下、用完还给用户"。
    func writeClipboardOnly(_ text: String) {
        saveForRestore()
        writeClipboard(text)
        // 给用户留手动 ⌘V 的时间，之后再还原
        scheduleRestore(delay: 8.0)
    }

    @discardableResult
    func paste(_ text: String, to pid: pid_t) -> Bool {
        // ① 在碰剪贴板之前，先快照用户原始内容
        saveForRestore()
        // ② 写入我们的文字供 ⌘V 使用
        writeClipboard(text)

        let sent = simulateCmdVviaPostToPid(pid: pid)
        Log.info("[Paste] postToPid ⌘V → pid=\(pid), sent=\(sent)")

        // 恢复策略：无论 ⌘V 是否成功，都延迟还原——
        // - 成功 → 2s 后还原（目标 app 已处理完粘贴）
        // - 失败 → 8s 后还原（给用户手动 ⌘V 的时间，然后归还剪贴板）
        scheduleRestore(delay: sent ? 2.0 : 8.0)
        return sent
    }

    // MARK: - 剪贴板保存与恢复

    /// 快照当前剪贴板（写入我们文字之前调用）：
    /// 立即把所有 item 的每种类型的数据读出来，重建为全新 NSPasteboardItem。
    /// 关键：绝不直接保存 `pasteboardItems` 原对象写回——它们是惰性的，
    /// 写回时 AppKit 会回调取数据，可能引用同一剪贴板造成主线程阻塞/死锁
    /// （正是此前"剪切板不还原 + 假死"的根因）。
    private func saveForRestore() {
        let savedItems = snapshotCurrentClipboard()
        let countAfterWrite = NSPasteboard.general.changeCount
        savedClipboard = SavedClipboard(items: savedItems, changeCountAfterWrite: countAfterWrite)
        Log.info("[Paste] 已快照剪贴板: \(savedItems.count) items")
    }

    /// 立即读取当前剪贴板全部数据，重建为带真实数据的 item。
    private func snapshotCurrentClipboard() -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { src -> NSPasteboardItem? in
            let dst = NSPasteboardItem()
            for type in src.types {
                if let data = src.data(forType: type) {
                    dst.setData(data, forType: type)
                }
            }
            return dst.types.isEmpty ? nil : dst
        }
    }

    /// 恢复剪贴板（如果用户在此期间没有手动复制新内容）。
    func restoreClipboard() {
        restoreWork?.cancel()
        restoreWork = nil
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let pb = NSPasteboard.general
        // changeCount 相对"我们写入后"又前进了 → 用户在此期间手动复制了内容，尊重它不覆盖
        guard pb.changeCount == saved.changeCountAfterWrite else {
            Log.info("[Paste] 剪贴板已被用户更新，跳过恢复（changeCount=\(pb.changeCount) != \(saved.changeCountAfterWrite)）")
            return
        }
        pb.clearContents()
        let ok = pb.writeObjects(saved.items)
        Log.info("[Paste] 剪贴板已恢复 ok=\(ok), items=\(saved.items.count)")
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
        Log.info("[Paste] 计划 \(String(format: "%.1f", delay))s 后还原剪贴板")
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
