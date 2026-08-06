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
        let savedItems = snapshotCurrentClipboard()
        writeClipboard(text)
        // 关键：countAfterWrite 必须在写入之后记录（早于写入会导致还原恒被跳过）
        savedClipboard = SavedClipboard(items: savedItems, changeCountAfterWrite: NSPasteboard.general.changeCount)
        // 给用户留手动 ⌘V 的时间，之后再还原
        scheduleRestore(delay: 8.0)
    }

    @discardableResult
    func paste(_ text: String, to pid: pid_t) -> Bool {
        // ① 在碰剪贴板之前，先快照用户原始内容
        let savedItems = snapshotCurrentClipboard()
        // ② 写入我们的文字供 ⌘V 使用
        writeClipboard(text)
        // ③ 写入后记录 changeCount，作为"用户是否又复制了新内容"的基准
        savedClipboard = SavedClipboard(items: savedItems, changeCountAfterWrite: NSPasteboard.general.changeCount)
        Log.info("[Paste] 已快照剪贴板: \(savedItems.count) items")

        let sent = simulateCmdV()
        Log.info("[Paste] 系统级 ⌘V → target pid=\(pid), sent=\(sent)")

        // 恢复策略：无论 ⌘V 是否成功，都延迟还原——
        // - 成功 → 1s 后还原（⌘V 的剪贴板读取通常在数百 ms 内完成；够快便于连续听写）
        // - 失败 → 8s 后还原（给用户手动 ⌘V 的时间，然后归还剪贴板）
        scheduleRestore(delay: sent ? 1.0 : 8.0)
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

    /// HID 级投递 ⌘V（enigo 键盘库的做法）。返回 true 表示事件已创建并投递。
    ///
    /// 之前"flag 式"投递（只投 V 的 down/up、带 .maskCommand）从没投 Command 自己的
    /// keyDown/keyUp，系统/目标 app 一直认为 Command 仍按住 → 粘贴后键盘被锁
    /// （shift+回车 失灵 / 全键失效，乱按才恢复）。且用 .combinedSessionState 源会
    /// 污染共享键盘状态。
    ///
    /// 正确做法：
    /// 1. .privateState 源：合成键不从 HID/会话继承或污染修饰键状态；
    /// 2. 完整修饰键生命周期：Cmd down → V down → V up → Cmd up；
    /// 3. 修饰键同时设高层 flag(.maskCommand) 与设备掩码 NX_DEVICELCMDKEYMASK(0x8)，
    ///    Cmd up 时清空——系统才认这是完整的 Command 按下/释放。
    /// 前置条件：面板已关闭、目标 App 已激活为 key window（confirmPaste 负责）。
    @discardableResult
    private func simulateCmdV() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9          // kVK_ANSI_V（QWERTY 物理键；中文拼音 IME 亦为 QWERTY 布局）
        let cmdKey: CGKeyCode = 55       // kVK_Command
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp     = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else {
            print("[Paste] CGEvent 创建失败")
            return false
        }
        let cmdFlags: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x00000008)] // NX_DEVICELCMDKEYMASK
        cmdDown.flags = cmdFlags
        vDown.flags = cmdFlags
        vUp.flags = cmdFlags
        cmdUp.flags = [] // 释放修饰键：清空标志
        cmdDown.post(tap: .cghidEventTap)
        usleep(20_000)
        vDown.post(tap: .cghidEventTap)
        usleep(20_000)
        vUp.post(tap: .cghidEventTap)
        usleep(20_000)
        cmdUp.post(tap: .cghidEventTap)
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
