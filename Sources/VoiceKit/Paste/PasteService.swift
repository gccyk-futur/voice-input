import AppKit
#if !APP_STORE
import ApplicationServices
#endif

/// 粘贴服务：写剪贴板并尝试向目标进程投递 ⌘V。
/// `postToPid` 没有提供目标控件实际插入的确认，因此始终保留手动粘贴窗口。
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
        let savedItems = snapshotCurrentClipboard()
        writeClipboard(text)
        // 关键：countAfterWrite 必须在写入之后记录（早于写入会导致还原恒被跳过）
        savedClipboard = SavedClipboard(items: savedItems, changeCountAfterWrite: NSPasteboard.general.changeCount)
        // 给用户留手动 ⌘V 的时间，之后再还原
        scheduleRestore(delay: PasteDeliveryPolicy.clipboardFallbackWindow)
    }

    /// Core Graphics 的合成键盘事件权限独立于 AX Accessibility 权限。
    /// App Store 沙盒版也可以使用该能力，但必须由用户在系统中授权。
    var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    func requestPostEventAccess() -> Bool {
        let granted = CGRequestPostEventAccess()
        Log.info("[Paste] PostEvent permission request result=\(granted)")
        return granted
    }

    @discardableResult
    func paste(_ text: String, to pid: pid_t) -> Bool {
        guard canPostEvents else {
            Log.error("[Paste] PostEvent 权限未授权，跳过 Cmd+V 投递")
            return false
        }

        // ① 在碰剪贴板之前，先快照用户原始内容
        let savedItems = snapshotCurrentClipboard()
        // ② 写入我们的文字供 ⌘V 使用
        writeClipboard(text)
        // ③ 写入后记录 changeCount，作为"用户是否又复制了新内容"的基准
        savedClipboard = SavedClipboard(items: savedItems, changeCountAfterWrite: NSPasteboard.general.changeCount)
        Log.info("[Paste] 已快照剪贴板: \(savedItems.count) items")

        let sent = simulateCmdVviaPostToPid(pid: pid)
        Log.info("[Paste] postToPid ⌘V → pid=\(pid), sent=\(sent)")

        // `sent` 只表示事件已派发，不表示目标控件实际完成了粘贴。
        // 无论结果如何，都保留完整的手动 ⌘V 窗口，避免自动失败后用户
        // 再按 ⌘V 时识别文本已经被过早恢复。
        scheduleRestore(delay: PasteDeliveryPolicy.clipboardFallbackWindow)
        return sent
    }

    // MARK: - 剪贴板保存与恢复

    /// 快照当前剪贴板（写入我们文字之前调用）：
    /// 立即把所有 item 的每种类型的数据读出来，重建为全新 NSPasteboardItem。
    /// 关键：绝不直接保存 `pasteboardItems` 原对象写回——它们是惰性的，
    /// 写回时 AppKit 会回调取数据，可能引用同一剪贴板造成主线程阻塞/死锁
    /// （正是此前"剪切板不还原 + 假死"的根因）。
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

    /// 使用已验证的 postToPid ⌘V 基线。
    ///
    /// 只投递带 `.maskCommand` 的 V down/up，不额外投递 Command 生命周期。
    /// 这是旧版 macOS 14+ 渠道包实际使用并验证过的方式。
    @discardableResult
    private func simulateCmdVviaPostToPid(pid: pid_t) -> Bool {
        let plan = CmdVEventPlan()
        let source = CGEventSource(stateID: .combinedSessionState)
        guard plan.isBalanced,
              let vDown = CGEvent(keyboardEventSource: source,
                                  virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source,
                                virtualKey: vKeyCode, keyDown: false) else {
            print("[Paste] CGEvent 创建失败")
            return false
        }

        // 目标应用只从 V 事件的 flags 判断 Command，避免给目标进程注入
        // 一组会残留或改变修饰键状态的 Command down/up。
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        let events: [(CmdVEventPlan.Event, CGEvent)] = [(.vDown, vDown), (.vUp, vUp)]
        for (_, event) in events {
            event.postToPid(pid)
            usleep(10_000)
        }
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

    func openPostEventSettings() {
        openPane("Privacy_Accessibility")
    }

    private func openPane(_ anchor: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
