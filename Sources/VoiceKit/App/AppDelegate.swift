import AppKit
import SwiftUI

/// 应用代理：使用 AppKit 原生 NSStatusItem + NSPopover 管理菜单栏图标，
/// 替代 SwiftUI 的 MenuBarExtra（后者在 SystemUIServer 重启 / 内存压力
/// / notch 隐藏等场景下会静默消失且无法自愈）。
///
/// 策略：
/// - 启动时创建 NSStatusItem 强引用（AppDelegate 持有，永不释放）
/// - NSPopover 内嵌 StatusBarMenuView，视觉与 MenuBarExtra(.window) 一致
/// - 每 5 秒巡检图标可见性，消失自动重建
/// - 监听唤醒/Space切换/分辨率变化事件立即检查恢复
/// - .accessory 策略：无 Dock、不出现 Cmd+Tab
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var monitorTimer: Timer?
    /// popover 显式关闭的全局/本地事件监听器（见 installPopoverDismissMonitors）
    private var eventShow: Any?
    private var eventShowLocal: Any?
    /// 检测到重复实例后的自我终止标记：跳过退出确认弹窗
    private var terminatingForDuplicateInstance = false

    // MARK: - 启动

    /// 启动回调由 SwiftUI 在正确的 MainActor 上下文调用（历史上从未崩过），
    /// 保持 @MainActor 原样，不再用 assumeIsolated 包裹（见 #89197：assumeIsolated
    /// 自身的 precondition 在 macOS 26 上也可能崩，避免在启动早期触碰它）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：必须在热键注册（AppCoordinator.init）与任何窗口之前执行。
        // 双实例会同 Bundle ID 同时响应全局热键、同时开麦克风、互相热重载覆盖
        // 同一份 config.json——发现已有实例时激活它并静默退出本实例。
        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
            if let existing = others.first {
                handleDuplicateInstance(existing)
                return
            }
        }

        continueLaunch()
    }

    /// 正常启动流程（单实例检查通过后执行）
    private func continueLaunch() {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        startMonitoring()
        observeSystemEvents()
        startMainThreadWatchdog()

        let coordinator = AppCoordinator.shared
        syncLoginItem()

        Task { @MainActor in
            if ConfigStore.shared.config.asr.engine == "aliyun" {
                await coordinator.prewarmAliyunEngine()
            }
        }

        if ConfigStore.shared.config.general.showSettingsOnLaunch {
            SettingsWindowController.shared.show()
        }
    }

    /// 发现已有实例时的处理。需要区分两种场景：
    /// - 应用内重启（SettingsView.restartApplication 用 createsNewApplicationInstance
    ///   先拉起新实例再 terminate 旧实例）：旧实例正在退出，稍等它终止后继续
    ///   正常启动，否则新实例会自杀、重启失败。
    /// - 用户真的重复打开（双击 App / open 第二次）：旧实例持续存活，等超时后
    ///   激活旧实例并静默退出本实例。
    private func handleDuplicateInstance(_ existing: NSRunningApplication) {
        print("[AppDelegate] 检测到已有 VoiceKit 实例 (pid \(existing.processIdentifier))，等待其退出（重启场景）")
        Task { @MainActor in
            // 最多等约 2 秒：覆盖旧实例 terminate 的常规耗时
            for _ in 0 ..< 20 {
                if existing.isTerminated {
                    print("[AppDelegate] 旧实例已退出，继续启动（应用内重启）")
                    continueLaunch()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("[AppDelegate] 旧实例仍在运行，激活它并退出本实例")
            terminatingForDuplicateInstance = true
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    /// 主线程看门狗（诊断）：后台心跳探测主线程响应性，超过 2 秒未响应则记日志。
    /// 用于确认"假死"是否主线程被阻塞、发生在哪个操作之后。
    private func startMainThreadWatchdog() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            while true {
                if self == nil { break }
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 2) == .timedOut {
                    Log.error("[Watchdog] 主线程超过 2 秒未响应")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    // MARK: - NSStatusItem

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceKit")
        button.action = #selector(togglePopover)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 重建状态栏图标（SystemUIServer 重启等场景后调用）
    private func rebuildStatusItem() {
        print("[AppDelegate] 检测到图标消失，重建 NSStatusItem")
        // 先移除旧的（如果有），避免泄漏
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
            statusItem = nil
        }
        setupStatusItem()
    }

    /// 巡检：图标是否还活着。
    /// button.window == nil → SystemUIServer 已移除该图标 → 重建。
    private func checkAndRestoreStatusItem() {
        guard let button = statusItem?.button else {
            rebuildStatusItem()
            return
        }
        if button.window == nil {
            rebuildStatusItem()
        }
    }

    // MARK: - NSPopover

    private func setupPopover() {
        popover.contentViewController = NSHostingController(rootView: StatusBarMenuView())
        popover.behavior = .transient // 点击外部自动关闭，标准菜单栏 App 行为
        popover.animates = true
    }

    /// 状态栏按钮 action。AppKit 经由 target/action 回调本方法，可能落在
    /// @MainActor @objc 隔离 thunk 上触发崩溃（macOS 26 / Swift 6 的
    /// swift_task_isMainExecutorImpl EXC_BAD_ACCESS）。
    /// 规避：nonisolated 入口，显式 Task { @MainActor } hop 后再执行。
    @objc nonisolated private func togglePopover() {
        Task { @MainActor [weak self] in
            self?.performTogglePopover()
        }
    }

    @MainActor
    private func performTogglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
            removePopoverDismissMonitors()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 外观在窗口层应用（popover 的窗口在 show 后才存在）
            popover.contentViewController?.view.window?.appearance = VoiceKitAppearance.current.nsAppearance
            // 确保 popover 成为 key window，否则文本选择等交互失效
            popover.contentViewController?.view.window?.makeKey()
            installPopoverDismissMonitors()
        }
    }

    /// 供外部（如 StatusBarMenuView 底部按钮）关闭 popover
    func dismissPopover() {
        if popover.isShown {
            popover.close()
        }
        removePopoverDismissMonitors()
    }

    // MARK: - Popover 显式关闭监听

    /// .transient 的「点外部自动关闭」在 macOS 26 上会被 nonactivating 悬浮面板、
    /// 截图工具等场景打断（popover 卡住不收起）。不再依赖系统机制：
    /// 显式监听 popover 之外的点击并主动关闭；点状态栏图标本身由 toggle 处理，需排除。
    private func installPopoverDismissMonitors() {
        removePopoverDismissMonitors()
        // 其他应用的点击（桌面、截图工具、其他 App 窗口）
        eventShow = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                // 点击状态栏图标本身不在这里关闭（由 toggle 处理）
                if let buttonWindow = self.statusItem?.button?.window,
                   NSPointInRect(NSEvent.mouseLocation, buttonWindow.frame) {
                    return
                }
                self.dismissPopover()
            }
        }
        // 本应用内其他窗口的点击（设置/历史/悬浮面板）
        eventShowLocal = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let self,
               self.popover.isShown,
               event.window != self.popover.contentViewController?.view.window,
               event.window != self.statusItem?.button?.window {
                self.dismissPopover()
            }
            return event
        }
    }

    private func removePopoverDismissMonitors() {
        if let monitor = eventShow {
            NSEvent.removeMonitor(monitor)
            eventShow = nil
        }
        if let monitor = eventShowLocal {
            NSEvent.removeMonitor(monitor)
            eventShowLocal = nil
        }
    }

    // MARK: - 定时巡检

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAndRestoreStatusItem()
            }
        }
        // 允许 timer 在 popover 打开时仍然运行
        if let timer = monitorTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    // MARK: - 系统事件监听

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleSystemEvent),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleSystemEvent),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleSystemEvent),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// 延迟 0.5s 后再检查——系统事件触发时菜单栏可能还没完成重排
    @objc nonisolated private func handleSystemEvent() {
        // 同样绕开 @MainActor @objc 隔离 thunk（见类注释）
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.checkAndRestoreStatusItem()
        }
    }

    // MARK: - 退出确认

    /// 退出确认路径从未出现在崩溃日志中，保持类级 @MainActor 原样。
    /// 不强行 nonisolated：NSAlert 在 macOS 26 SDK 上是 @MainActor 隔离类型，
    /// 避免为未崩溃的路径引入假设。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 重复实例的静默自我终止：不弹退出确认
        if terminatingForDuplicateInstance { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = VoiceKitLocalization.string("退出 VoiceKit？")
        alert.informativeText = VoiceKitLocalization.string("退出后语音识别服务将停止运行，菜单栏图标也会消失。")
        alert.addButton(withTitle: VoiceKitLocalization.string("退出"))
        alert.addButton(withTitle: VoiceKitLocalization.string("取消"))
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - 双击唤醒

    /// 用 Task{@MainActor} 延后调度，避免同步的 assumeIsolated precondition。
    /// #89197 的崩溃发生在方法体执行前，nonisolated 入口 + 延后调度可完全绕开。
    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Log.info("[AppDelegate] applicationShouldHandleReopen → 显示设置窗口")
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
        return true
    }

    // MARK: - 登录项

    private func syncLoginItem() {
        LoginItemManager.set(enabled: ConfigStore.shared.config.general.launchAtStartup)
    }
}
