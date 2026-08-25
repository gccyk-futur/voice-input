import AppKit
import Foundation

/// 从历史记录「重新粘贴」：把某条历史写回用户之前所在的 App。
///
/// 与主听写链路的差异：历史窗口打开时目标可能已经变了，因此这里
/// 以「打开历史窗口前的最后一个前台应用」为目标（HistoryWindowController
/// 记录在 previousFrontmostApp）。永远保留剪贴板兜底，失败不影响用户手动 ⌘V。
@MainActor
final class HistoryReuseService {
    static let shared = HistoryReuseService()
    private let pasteService = PasteService.shared

    enum Result {
        /// 已自动粘回目标应用
        case pasted
        /// 仅复制到剪贴板（无目标 / 无键盘事件权限 / 投递失败）
        case copiedOnly
        /// 无目标应用可写回
        case noTarget
    }

    /// 重新粘贴。onResult 在主线程回调，供调用方展示提示。
    func repaste(_ text: String, to target: NSRunningApplication?, onResult: @escaping (Result) -> Void) {
        guard let target, !target.isTerminated else {
            pasteService.writeClipboardOnly(text, retentionSeconds: 0)
            onResult(.noTarget)
            return
        }

        // 与主听写链路一致的配合激活：先让出激活权，再请求目标激活。
        NSApp.yieldActivation(to: target)
        _ = target.activate()
        let pid = target.processIdentifier

        // 目标激活是异步请求；下个主循环再投递，命中目标窗口。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.pasteService.canPostEvents {
                let ok = self.pasteService.paste(text, to: pid)
                onResult(ok ? .pasted : .copiedOnly)
            } else {
                self.pasteService.writeClipboardOnly(text, retentionSeconds: 0)
                onResult(.copiedOnly)
            }
        }
    }
}
