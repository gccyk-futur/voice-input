import Foundation
import SwiftUI
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif
import AVFoundation

/// 应用中枢：持有各服务，驱动会话状态机（idle→recording→transcribing→polishing→ready）。
@MainActor
@Observable
final class AppCoordinator {
    enum SessionState: Equatable {
        case idle, preparing, recording, transcribing, polishing, ready, failed
    }

    var sessionState: SessionState = .idle
    var asrText: String = ""
    var llmText: String = ""
    var statusText: String = VoiceKitLocalization.string("按 ⌘⇧V 开始")
    var audioLevel: Float = 0
    var recoveryNotice: RecordingRecoveryNotice?

    // MARK: - 状态栏展示用的实时状态（@Observable 存储属性，变更驱动 UI 刷新）
    /// 当前选择的 ASR 引擎 id（"system" | "aliyun"）。
    var asrEngineChoice: String = "system"
    /// 阿里云是否已配置 apiKey/workspaceId（决定是否显示双引擎切换）。
    var aliyunConfigured: Bool = false
    /// 阿里云 WebSocket 是否已连接。
    var wsConnected: Bool = false
    /// 阿里云连接状态文字（"已连接" / "连接中…" / "已断开，2.4s 后自动重连"）。
    var wsStatusText: String = VoiceKitLocalization.string("未连接")

    private let configStore = ConfigStore.shared
    private let historyStore = HistoryStore.shared
    private let pasteService = PasteService.shared
    private let hotkey = HotkeyManager.shared
    private let panel = FloatingPanelController()

    private var asrEngine: (any ASREngine)?
    func invalidateASREngine() { asrEngine = nil }
    private var llmEngine: (any LLMEngine)?
    /// 识别开始时前台的目标 app（文字应插入它的输入框）；停止时把焦点还给它。
    private var targetApp: NSRunningApplication?
    /// 收尾标记：自动粘贴流程进行中。此时面板关闭触发的 cancel 应被忽略，避免双重复位。
    private var finalizing = false
    /// 引擎的 start/stop/finish 流程未完成时，禁止下一次 F2 重新进入同一引擎。
    private var engineOperationInFlight = false
    private var stopTask: Task<Void, Never>?
    /// A runtime engine failure can arrive while stop/cancel is already
    /// awaiting the engine. Let that teardown task consume the error instead
    /// of racing it with an independent idle/reset transition.
    private var pendingRuntimeFailure: Error?
    /// 防止用户在 resolveASR 尚未完成时取消，旧的异步结果又启动幽灵会话。
    private var recordingFlowGate = RecordingFlowGate()
    private var resolvingASRTask: Task<Void, Never>?
    private var engineStartTask: Task<Void, Never>?
    /// 权限请求回调可能晚于用户取消返回；用 token 丢弃过期回调。
    private var permissionRequestID: UUID?
    /// 持有最近一次提示音，避免 fire-and-forget 的 NSSound 被过早释放。
    private var activeSound: NSSound?

    // MARK: - Display Sync (LLM 流式文字 → UI 解耦)

    /// LLM token 流写入此 buffer（不触发 UI）。
    private var llmBuffer: String = ""
    /// 按固定间隔将 buffer 同步到 @Observable llmText。
    private var displayTimer: Timer?

    static let shared = AppCoordinator()

    /// 菜单栏状态（供 StatusBarMenu 读取）
    var engineDisplayName: String {
        asrEngineChoice == "aliyun"
            ? VoiceKitLocalization.string("阿里云 Fun-ASR")
            : VoiceKitLocalization.string("系统听写")
    }
    var llmEnabled: Bool { configStore.config.llm.enabled }

    init() {
        // 从当前配置初始化状态栏展示状态
        let cfg = configStore.config
        asrEngineChoice = cfg.asr.engine
        aliyunConfigured = !cfg.asr.aliyun.apiKey.isEmpty && !cfg.asr.aliyun.workspaceId.isEmpty

        hotkey.onActivate = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        hotkey.register(hotkeyString: configStore.config.general.hotkey)
        panel.setCoordinator(self)

        // 配置变更（设置中保存、热重载）→ 同步状态栏展示状态
        NotificationCenter.default.addObserver(
            forName: ConfigStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshEngineStatus() }
        }
    }

    /// 依据配置与当前引擎刷新状态栏展示状态（引擎选择、阿里云配置/连接状态）。
    private func refreshEngineStatus() {
        let cfg = configStore.config
        asrEngineChoice = cfg.asr.engine
        aliyunConfigured = !cfg.asr.aliyun.apiKey.isEmpty && !cfg.asr.aliyun.workspaceId.isEmpty
        wsConnected = (asrEngine as? AlibabaASREngine)?.wsConnected ?? false
        if !aliyunConfigured {
            wsStatusText = VoiceKitLocalization.string("未连接")
        }
    }

    // MARK: - 状态机

    func toggleRecording() {
        switch sessionState {
        case .idle: startRecording()
        case .recording: stopAndProcess()
        default:
            // 转写/润色中：等待流水线自动粘贴，忽略重复热键，避免重复提交；
            // 就绪态已由 handleFinal 自动粘贴并复位。
            break
        }
    }

    func startRecording() {
        guard sessionState == .idle,
              !engineOperationInFlight,
              stopTask == nil,
              permissionRequestID == nil else {
            Log.info("[Coordinator] startRecording ignored: state=\(sessionState), engineOperationInFlight=\(engineOperationInFlight)")
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        Log.info("[Coordinator] startRecording: micStatus=\(micStatus.rawValue), speechStatus=\(speechStatus.rawValue)")

        if micStatus == .denied || speechStatus == .denied {
            presentPermissionError(micDenied: micStatus == .denied, speechDenied: speechStatus == .denied)
            return
        }

        if micStatus == .notDetermined || speechStatus == .notDetermined {
            requestPendingPermissions(micNeeded: micStatus == .notDetermined,
                                       speechNeeded: speechStatus == .notDetermined)
            return
        }

        beginRecordingFlow()
    }

    /// 显式请求未决定的权限。
    /// 必须用 Task.detached：AVCaptureDevice / SFSpeechRecognizer
    /// 权限回调在后台线程触发，与 MainActor 隔离的 CheckedContinuation 冲突会在 Debug 构建崩溃。
    private func requestPendingPermissions(micNeeded: Bool, speechNeeded: Bool) {
        let requestID = UUID()
        permissionRequestID = requestID
        panel.show()
        Task.detached { [weak self] in
            guard let self else { return }
            if micNeeded {
                let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
                }
                Log.info("[Coordinator] microphone requestAccess result: \(granted)")
                guard granted else {
                    await MainActor.run { [weak self] in
                        guard let self, self.permissionRequestID == requestID else { return }
                        self.permissionRequestID = nil
                        self.panel.close()
                        self.presentPermissionError(micDenied: true, speechDenied: false)
                    }
                    return
                }
            }
            if speechNeeded {
                let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
                }
                Log.info("[Coordinator] speech requestAuthorization result: \(granted)")
                guard granted else {
                    await MainActor.run { [weak self] in
                        guard let self, self.permissionRequestID == requestID else { return }
                        self.permissionRequestID = nil
                        self.panel.close()
                        self.presentPermissionError(micDenied: false, speechDenied: true)
                    }
                    return
                }
            }
            // 全部通过，继续听写流程
            await MainActor.run { [weak self] in
                guard let self, self.permissionRequestID == requestID else { return }
                self.permissionRequestID = nil
                self.beginRecordingFlow()
            }
        }
    }

    /// 已授权的正常听写启动流程。先解析引擎，Direct 启动。
    private func beginRecordingFlow() {
        let generation = recordingFlowGate.begin()
        targetApp = hotkey.capturedTargetApp ?? NSWorkspace.shared.frontmostApplication
        hotkey.capturedTargetApp = nil
        Log.info("[Coordinator] targetApp=\(targetApp?.localizedName ?? "nil")")
        asrText = ""
        llmText = ""
        recoveryNotice = nil
        sessionState = .preparing
        statusText = VoiceKitLocalization.string("准备中…")
        // 面板可以即时反馈快捷键已经生效，但只有音频引擎真正启动后才显示“聆听中”。
        panel.show()

        let languageID = configStore.config.asr.system.language
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let engine = await self.resolveASR()
            guard !Task.isCancelled,
                  self.recordingFlowGate.accepts(generation),
                  self.sessionState == .preparing else {
                return
            }
            self.resolvingASRTask = nil
            self.asrEngine = engine
            // 本地引擎：传入静音检测配置
            if let legacy = engine as? LegacyDictationEngine {
                let cfg = configStore.config.asr.system
                legacy.configureAutoStop(
                    enabled: cfg.silenceAutoStopEnabled,
                    timeout: cfg.silenceTimeout,
                    threshold: Float(cfg.silenceThreshold)
                )
                Log.info("[Coordinator] autoStop configured: enabled=\(cfg.silenceAutoStopEnabled) timeout=\(cfg.silenceTimeout)s threshold=\(cfg.silenceThreshold)")
            }
            panel.show(needsActivation: engine.requiresForeground)
            panel.makeKey()
            Log.info("[Coordinator] starting \(engine.displayName), needsActivation=\(engine.requiresForeground)")
            startEngine(engine, languageID: languageID, generation: generation)
        }
        resolvingASRTask = task
    }

    /// 启动 ASR 引擎并处理错误。
    private func startEngine(_ engine: any ASREngine, languageID: String, generation: UUID) {
        engineOperationInFlight = true
        // 音波电平通知
        let onLevel: (@Sendable (Float) -> Void)? = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        // 静音超时自动停止
        let onSilence: (@Sendable () -> Bool)? = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionState == .recording else { return }
                self.stopAndProcess()
            }
            return true
        }
        // 飞行中失败（麦克风断开、云端连接中断等）：结束本次会话并显示可恢复状态。
        engine.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self,
                      self.sessionState != .idle,
                      self.sessionState != .failed else { return }
                Log.error("[Coordinator] engine runtime failure: \(error)")
                self.recordingFlowGate.invalidate()
                self.resolvingASRTask?.cancel()
                self.resolvingASRTask = nil
                if self.stopTask != nil {
                    // stop()/cancel() owns teardown now; it will surface the
                    // error after its engine await has completed.
                    self.pendingRuntimeFailure = error
                    return
                }
                self.pendingRuntimeFailure = nil
                self.engineOperationInFlight = false
                self.presentRecoveryFailure(error)
            }
        }
        let startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.engineStartTask = nil }
            do {
                try await engine.start(locale: Locale(identifier: languageID),
                    onPartial: { [weak self] partial in
                        Task { @MainActor in self?.asrText = partial }
                    },
                    onAudioLevel: onLevel,
                    onAutoStop: onSilence
                )

                // 若 cancel/stop 已经发生，stopTask 会在这个 start 返回后负责清理；
                // 若没有 stopTask，则由这里处理迟到的成功，避免 idle 状态下继续录音。
                let shouldKeepRunning = self.recordingFlowGate.accepts(generation)
                    && self.sessionState == .preparing
                    && self.asrEngine?.id == engine.id
                    && self.stopTask == nil
                guard shouldKeepRunning else {
                    if self.stopTask == nil {
                        _ = try? await engine.stop()
                    }
                    return
                }
                self.sessionState = .recording
                self.statusText = VoiceKitLocalization.string("聆听中…")
                self.recoveryNotice = nil
                let sound = self.configStore.config.general.sound
                self.playSound(named: sound.startSound, enabled: sound.start)
                self.engineOperationInFlight = false
            } catch {
                Log.error("[Coordinator] engine.start failed: \(error)")
                // 若 cancel 正在等待 engine.stop()，由 cancel 的收尾统一复位，
                // 避免 start 的失败回调抢先 reset 并放开下一次 F2。
                guard self.stopTask == nil else { return }
                self.recordingFlowGate.invalidate()
                self.engineOperationInFlight = false
                self.presentRecoveryFailure(error)
            }
        }
        engineStartTask = startTask
    }

    /// 双通道抢占前台：NSApp.activate（AppKit）+ clickToActivate（CGEvent 模拟点击），
    /// 持续 3s 覆盖 DictationTranscriber 初始化全过程。对抗 iTerm2 等 reclaim 行为。
    func stopAndProcess() {
        Log.info("[Coordinator] stopAndProcess() called, sessionState=\(sessionState), engine=\(asrEngine != nil)")
        guard stopTask == nil else { return }
        // F2 may arrive while resolveASR is still suspended (for example while
        // a cloud engine is being constructed). Treat that press as a real
        // cancellation instead of leaving the coordinator stuck in .recording
        // with a late engine that can start a ghost session.
        guard let engine = asrEngine else {
            guard resolvingASRTask != nil else { return }
            Log.info("[Coordinator] stop requested while resolving ASR; cancel pending resolution")
            cancel()
            return
        }
        engineOperationInFlight = true
        sessionState = .transcribing
        statusText = VoiceKitLocalization.string("转写中…")
        let pendingStart = engineStartTask
        let task = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            let final = (try? await engine.stop()) ?? self.asrText
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.engineOperationInFlight = false
                    self.stopTask = nil
                }
                return
            }
            let runtimeFailure = await MainActor.run { () -> Error? in
                let failure = self.pendingRuntimeFailure
                self.pendingRuntimeFailure = nil
                return failure
            }
            if let runtimeFailure {
                await MainActor.run {
                    self.engineOperationInFlight = false
                    self.stopTask = nil
                    self.reset()
                    self.statusText = VoiceKitLocalization.format("听写中断：%@", runtimeFailure.localizedDescription)
                }
                return
            }
            await self.handleFinal(asr: final)
            await MainActor.run {
                self.engineOperationInFlight = false
                self.stopTask = nil
            }
        }
        stopTask = task
    }

    private func handleFinal(asr final: String) async {
        asrText = final
        // 未识别到任何内容：不进入润色/粘贴流程，直接关闭复位。
        // 既避免"空粘贴"打断用户，也避免空字符串写入/覆盖剪贴板。
        if final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.info("[Coordinator] ASR 结果为空，跳过润色/粘贴")
            await MainActor.run {
                self.reset()
                self.statusText = VoiceKitLocalization.string("未识别到内容")
            }
            return
        }
        let cfg = configStore.config
        if cfg.llm.enabled, let llm = resolveLLM() {
            llmEngine = llm
            sessionState = .polishing
            statusText = VoiceKitLocalization.string("润色中…")
            llmText = ""
            llmBuffer = ""
            startDisplaySync()
            let tmpl = PromptTemplate(system: cfg.llm.activePrompt.system, user: cfg.llm.activePrompt.user)
            let (sys, usr) = tmpl.render(input: final, language: cfg.asr.system.language, engine: llm.id)
            Log.info("[LLM] 模型=\(cfg.llm.selectedModel?.name ?? "?") 引擎=\(llm.id) url=\(cfg.llm.selectedModel?.baseUrl ?? "?") model=\(cfg.llm.selectedModel?.model ?? "?")")
            Log.info("[LLM] system=\(sys.prefix(80))... user=\(usr.prefix(80))...")
            do {
                for try await chunk in llm.polish(final, system: sys, userTemplate: usr) {
                    llmBuffer += chunk
                }
                stopDisplaySync()
                llmText = llmBuffer
                Log.info("[LLM] 润色成功, \(llmBuffer.count) 字符")
                // 累加 token 统计
                let total = llm.lastPromptTokens + llm.lastCompletionTokens
                if total > 0, !cfg.llm.selectedModelID.isEmpty {
                    configStore.addLLMTokenUsage(modelID: cfg.llm.selectedModelID, tokens: total)
                }
            } catch {
                stopDisplaySync()
                Log.error("[LLM] 润色失败: \(error)")
                llmText = final
            }
            sessionState = .ready
        } else {
            sessionState = .ready
        }
        // 到达就绪态：自动粘贴
        await MainActor.run {
            let sound = self.configStore.config.general.sound
            self.playSound(named: sound.stopSound, enabled: sound.stop)
            self.confirmPaste()
        }
    }

    func confirmPaste() {
        guard sessionState == .ready else { return }
        finalizing = true
        let useLLM = configStore.config.llm.enabled && !llmText.isEmpty
        let text = useLLM ? llmText : asrText
        let target = targetApp
        targetApp = nil

        // 先关闭面板
        panel.close()

        Log.info("[Paste] confirmPaste target=\(target?.localizedName ?? "nil"), textLen=\(text.count)")
        Log.info("[Paste] 文本内容: \(text.debugDescription.prefix(120))")

        // 没有可用目标时只能保留剪贴板，不能声称已经写回。
        guard let target, !target.isTerminated else {
            pasteService.writeClipboardOnly(text)
            finalizeAndRecord(useLLM: useLLM, statusText: VoiceKitLocalization.string("已复制到剪贴板"))
            return
        }

        let targetPID = target.processIdentifier

        // .nonactivatingPanel 不会把焦点交还给目标 App。遵循 AppKit 的
        // cooperative activation：当前 App 先让出激活权，再请求目标激活。
        NSApp.yieldActivation(to: target)
        let activationRequested = target.activate()
        Log.info("[Paste] target activation requested name=\(target.localizedName ?? "unknown"), pid=\(targetPID), allowed=\(activationRequested)")

        // activate() 是异步请求；下一次主循环再读取焦点并投递 Cmd+V，避免
        // 在目标 App 尚未完成激活时发送事件。
        DispatchQueue.main.async { [weak self] in
            self?.deliverPaste(
                text: text,
                useLLM: useLLM,
                target: target,
                targetPID: targetPID,
                activationRequested: activationRequested
            )
        }
    }

    private func deliverPaste(
        text: String,
        useLLM: Bool,
        target: NSRunningApplication,
        targetPID: pid_t,
        activationRequested: Bool
    ) {
        Log.info("[Paste] target active=\(target.isActive), activationAllowed=\(activationRequested)")

#if APP_STORE
        // Keep the channel build on the same automatic delivery path as the
        // direct build. If automatic delivery is not selected, retain the
        // clipboard and clearly ask the user to paste manually.
        switch PasteDeliveryPolicy.mode(isAppStore: true) {
        case .clipboardOnly:
            pasteService.writeClipboardOnly(text)
            finalizeAndRecord(useLLM: useLLM, statusText: VoiceKitLocalization.string("已复制到剪贴板（请手动 ⌘V）"))
            return
        case .automatic:
            break
        }
#endif

#if !APP_STORE
        // 官网版策略1：Accessibility API 直插（主力方案，不动剪贴板、不切换焦点）
        let axService = AccessibilityPasteService.shared
        if axService.isTrusted {
            let inserted = axService.insertText(text)
            if inserted {
                Log.info("[Paste] Accessibility 直插成功")
                finalizeAndRecord(useLLM: useLLM, statusText: nil)
                return
            }
            // 直插失败（目标元素不支持设置选中文本等）→ 回退剪贴板+⌘V。
            Log.info("[Paste] Accessibility 直插失败（属性不可写等），回退剪贴板方案")
        } else {
            // 辅助功能能力真实不可用 → 不假装粘贴：只写剪贴板 + 诚实提示。
            // 此时 ⌘V 投递同样会被拦，做了也是假成功。
            Log.error("[Paste] 辅助功能未授权，仅复制到剪贴板并提示用户")
            pasteService.writeClipboardOnly(text)
            finalizeAndRecord(
                useLLM: useLLM,
                statusText: VoiceKitLocalization.string("已复制到剪贴板。未授权辅助功能，请按 ⌘V 手动粘贴（系统设置→隐私与安全性→辅助功能）")
            )
            return
        }
#endif

        let preflightGranted = pasteService.canPostEvents
        let requestGranted = preflightGranted ? false : pasteService.requestPostEventAccess()
        let postEventDecision = PasteDeliveryPolicy.postEventDecision(
            preflightGranted: preflightGranted,
            requestGranted: requestGranted
        )
        Log.info("[Paste] PostEvent access preflight=\(preflightGranted), request=\(requestGranted), decision=\(postEventDecision)")

        guard postEventDecision == .automatic else {
            pasteService.writeClipboardOnly(text)
            finalizeAndRecord(
                useLLM: useLLM,
                statusText: VoiceKitLocalization.string("已复制到剪贴板，请按 ⌘V；授权键盘事件后可自动写回")
            )
            return
        }

        // 剪贴板 + Cmd+V。paste() 内部会保存原剪贴板 → 写入文字 → ⌘V →
        // 延迟恢复，不要在此预先写入，否则快照到的将是我们自己写入的内容。
        let pasteOK = pasteService.paste(text, to: targetPID)
        Log.info("[Paste] Cmd+V event dispatched=\(pasteOK); insertion remains unverified")

        // PostEvent 权限已授权且事件成功派发时不再弹出误导性的“请按 ⌘V”。
        // 事件创建失败时仍保留诚实的剪贴板兜底提示。
        finalizeAndRecord(
            useLLM: useLLM,
            statusText: pasteOK ? nil : VoiceKitLocalization.string("自动写回失败，文字仍在剪贴板，请按 ⌘V")
        )
    }

    private func finalizeAndRecord(useLLM: Bool, statusText: String?) {
        // 组合兜底提示：官网版未授权辅助功能时顺带引导授权
        var notice = statusText
#if !APP_STORE
        if !AccessibilityPasteService.shared.isTrusted {
            notice = (notice ?? "") + " " + VoiceKitLocalization.string("授权辅助功能后可自动输入")
        }
#endif
        historyStore.append(HistoryItem(
            asrResult: asrText,
            llmResult: useLLM ? llmText : nil,
            engine: asrEngine?.id ?? "system",
            llmEngine: useLLM ? (configStore.config.llm.selectedModel?.engine) : nil
        ))
        reset()
        finalizing = false

        // 剪贴板兜底路径不能静默（也不能被误认为已成功写入）：
        // 以独立吐司通知提示，不重新拉起听写面板，约 4 秒后自动消散。
        if let notice, !notice.trimmingCharacters(in: .whitespaces).isEmpty {
            ToastController.shared.show(notice, duration: 4)
        }
    }

    func cancel() {
        Log.info("[Coordinator] cancel() called, sessionState=\(sessionState), finalizing=\(finalizing)")
        if finalizing { return }
        // 上一次 stop/finish 尚未完成时，重复 F2 只忽略，不能启动新的云端 task。
        if stopTask != nil { return }

        let pendingStart = engineStartTask
        recordingFlowGate.invalidate()
        resolvingASRTask?.cancel()
        resolvingASRTask = nil
        permissionRequestID = nil

        if let engine = asrEngine,
           sessionState != .idle,
           (engineOperationInFlight || sessionState == .recording) {
            engineOperationInFlight = true
            sessionState = .transcribing
            statusText = VoiceKitLocalization.string("正在停止…")
            stopDisplaySync()
            let previousTarget = targetApp
            let task = Task { [weak self] in
                guard let self else { return }
                await pendingStart?.value
                _ = try? await engine.stop()
                await MainActor.run {
                    let runtimeFailure = self.pendingRuntimeFailure
                    self.pendingRuntimeFailure = nil
                    self.engineOperationInFlight = false
                    self.stopTask = nil
                    self.reset()
                    if let runtimeFailure {
                        self.presentRecoveryFailure(runtimeFailure)
                    }
                    previousTarget?.activate()
                    self.targetApp = nil
                }
            }
            stopTask = task
            return
        }

        // idle 态（如启动失败后）也必须关面板，否则 Esc/关闭按钮无法收起悬浮窗。
        stopDisplaySync()
        reset()
        // 归还焦点给之前的应用
        if let t = targetApp { t.activate() }
        targetApp = nil
    }

    // MARK: - Display Sync

    /// 启动定时器，按 60fps 将 llmBuffer 同步到 @Observable llmText。
    /// LLM token 流写入 buffer（不触发 UI），定时器按屏幕刷新节奏拉取到 UI 层，
    /// 避免高频 token 推送导致 SwiftUI body 过度重新求值。
    private func startDisplaySync() {
        stopDisplaySync()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.llmBuffer
                if self.llmText != current {
                    self.llmText = current
                }
            }
        }
        if let timer = displayTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopDisplaySync() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func playSound(named name: String, enabled: Bool) {
        guard enabled else {
            activeSound = nil
            return
        }
        activeSound = NSSound(named: .init(name))
        activeSound?.play()
    }

    private func reset() {
        recordingFlowGate.invalidate()
        resolvingASRTask?.cancel()
        resolvingASRTask = nil
        engineStartTask?.cancel()
        engineStartTask = nil
        permissionRequestID = nil
        pendingRuntimeFailure = nil
        stopDisplaySync()
        if asrEngine?.id != "aliyun" {
            invalidateASREngine()
        }
        llmEngine = nil
        asrText = ""
        llmText = ""
        recoveryNotice = nil
        sessionState = .idle
        statusText = VoiceKitLocalization.string("按 ⌘⇧V 开始")
        panel.close()
    }

    /// 权限被拒时：在面板显示可读提示，由用户点击按钮打开对应系统设置页。
    private func presentPermissionError(micDenied: Bool, speechDenied: Bool) {
        asrText = ""
        llmText = ""
        sessionState = .failed
        if micDenied {
            recoveryNotice = .forKind(.microphonePermission)
        } else {
            recoveryNotice = .forKind(.speechPermission)
        }
        statusText = ""
        panel.show()
    }

    func retryRecording() {
        guard sessionState == .failed else { return }
        reset()
        startRecording()
    }

    func performRecoveryAction(_ action: RecordingRecoveryAction) {
        switch action {
        case .retry:
            retryRecording()
        case .openInputSettings:
            openInputSettings()
        case .openMicrophoneSettings:
            pasteService.openMicrophoneSettings()
        case .openSpeechSettings:
            pasteService.openSpeechSettings()
        }
    }

    private func openInputSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") else { return }
        NSWorkspace.shared.open(url)
    }

    private func presentRecoveryFailure(_ error: Error) {
        recoveryNotice = .forKind(Self.recoveryKind(for: error))
        sessionState = .failed
        statusText = ""
        panel.show()
    }

    private static func recoveryKind(for error: Error) -> RecordingFailureKind {
        if let audioError = error as? ASRError {
            switch audioError {
            case .microphoneNotAuthorized:
                return .microphonePermission
            case .speechNotAuthorized:
                return .speechPermission
            case .noInputDevice:
                return .noInputDevice
            case .noAudioFormat, .converterInit, .audioEngineStartFailed:
                return .audioInputUnavailable
            case .noSpeechAsset, .speechNotAvailable:
                return .speechUnavailable
            }
        }
        return .serviceUnavailable
    }

    // MARK: - 引擎解析（可插拔）

    /// 选择 ASR 引擎：遵从用户设置。
    /// - "system"：SFSpeechRecognizer（稳定，无需前台，自动本地/云端路由）
    /// - "dictation"：DictationTranscriber（原生连续听写，需前台）
    /// - "aliyun"：阿里云 Fun-ASR WebSocket（在线，高精度带标点，常驻连接）
    /// - "xunfei"：讯飞语音听写流式 WebSocket（在线，中文高精度，每会话一条连接）
    /// - "deepgram"：Deepgram 流式 WebSocket（在线，海外高精度，每会话一条连接）
    func resolveASR() async -> any ASREngine {
        Log.info("[Coordinator] resolveASR: engine config = \(configStore.config.asr.engine)")
        switch configStore.config.asr.engine {
        case "dictation":
            if #available(macOS 26, *) {
                let raw = configStore.config.asr.system.language
                let loc = Locale(identifier: raw)
                if await DictationTranscriber.supportedLocale(equivalentTo: loc) != nil {
                    return SystemDictationEngine()
                }
            }
            return await resolveAliyun()
        case "aliyun":
            return await resolveAliyun()
        case "xunfei":
            let cfg = configStore.config.asr.xunfei
            if !cfg.appId.isEmpty, !cfg.apiKey.isEmpty, !cfg.apiSecret.isEmpty {
                return XunfeiASREngine(
                    appId: cfg.appId, apiKey: cfg.apiKey, apiSecret: cfg.apiSecret,
                    dynamicCorrection: cfg.dynamicCorrection,
                    autoStopEnabled: cfg.autoStopEnabled,
                    autoStopTimeout: cfg.autoStopTimeout,
                    autoStopThreshold: Float(cfg.autoStopThreshold)
                )
            }
            Log.info("[Coordinator] 讯飞听写未配置 appId/apiKey/apiSecret，自动切回 system")
            fallbackToSystem()
            return await resolveSystemEngine()
        case "deepgram":
            let cfg = configStore.config.asr.deepgram
            if !cfg.apiKey.isEmpty {
                return DeepgramASREngine(
                    apiKey: cfg.apiKey, model: cfg.model,
                    autoStopEnabled: cfg.autoStopEnabled,
                    autoStopTimeout: cfg.autoStopTimeout,
                    autoStopThreshold: Float(cfg.autoStopThreshold)
                )
            }
            Log.info("[Coordinator] Deepgram 未配置 apiKey，自动切回 system")
            fallbackToSystem()
            return await resolveSystemEngine()
        default:
            return await resolveSystemEngine()
        }
    }

    /// 阿里云引擎解析：复用常驻连接；未配置时回退系统引擎。
    private func resolveAliyun() async -> any ASREngine {
        if let existing = asrEngine as? AlibabaASREngine {
            wireAliyunCallbacks(existing)
            return existing
        }
        let cfg = configStore.config.asr.aliyun
        if !cfg.apiKey.isEmpty, !cfg.workspaceId.isEmpty {
            return makeAliyunEngine(cfg: cfg)
        }
        Log.info("[Coordinator] Aliyun ASR 未配置 apiKey/workspaceId，自动切回 system")
        // 自动回退：把配置写回 system，下次就不用再判断了
        fallbackToSystem()
        return await resolveSystemEngine()
    }

    /// 自动回退：把引擎配置写回 system，下次就不用再判断了。
    private func fallbackToSystem() {
        var corrected = configStore.config
        corrected.asr.engine = "system"
        configStore.update(corrected)
    }

    /// 系统引擎解析：SFSpeechRecognizer 可用则用 legacy，否则尝试 macOS 26 听写。
    private func resolveSystemEngine() async -> any ASREngine {
        let raw = configStore.config.asr.system.language
        let loc = Locale(identifier: raw)
        let recognizer = SFSpeechRecognizer(locale: loc)
        if let recognizer, recognizer.isAvailable {
            return LegacyDictationEngine()
        }
        if #available(macOS 26, *),
           await DictationTranscriber.supportedLocale(equivalentTo: loc) != nil {
            return SystemDictationEngine()
        }
        return LegacyDictationEngine()
    }

    /// 创建阿里云引擎并挂接连接状态/失败回调。
    private func makeAliyunEngine(cfg: ASRAliyunConfig) -> AlibabaASREngine {
        let engine = AlibabaASREngine(
            apiKey: cfg.apiKey, workspaceId: cfg.workspaceId, region: cfg.region, model: cfg.model,
            semanticPunctuation: cfg.semanticPunctuation,
            speechNoiseThreshold: cfg.speechNoiseThreshold,
            maxSentenceSilence: cfg.maxSentenceSilence,
            autoStopEnabled: cfg.autoStopEnabled,
            autoStopTimeout: cfg.autoStopTimeout,
            autoStopThreshold: Float(cfg.autoStopThreshold)
        )
        wireAliyunCallbacks(engine)
        return engine
    }

    /// 给阿里云引擎挂接连接状态变化 / 运行时失败回调（幂等）。
    private func wireAliyunCallbacks(_ engine: AlibabaASREngine) {
        engine.onConnectionChange = { [weak self] connected, status in
            Task { @MainActor in
                self?.wsConnected = connected
                self?.wsStatusText = status
            }
        }
        // 初始同步一次当前状态
        wsConnected = engine.wsConnected
        wsStatusText = engine.wsConnected
            ? VoiceKitLocalization.string("已连接")
            : VoiceKitLocalization.string("未连接")
    }

    /// 预建连阿里云引擎：切到阿里云时主动创建，让状态灯能正确显示连接状态。
    func prewarmAliyunEngine() async {
        if asrEngine is AlibabaASREngine { return } // 已有引擎，无需重建
        let cfg = configStore.config.asr.aliyun
        guard !cfg.apiKey.isEmpty, !cfg.workspaceId.isEmpty else { return }
        let engine = makeAliyunEngine(cfg: cfg)
        self.asrEngine = engine
        Log.info("[Coordinator] 阿里云引擎预建连完成")
    }

    func resolveLLM() -> (any LLMEngine)? {
        let cfg = configStore.config.llm
        guard let model = cfg.selectedModel else { return nil }
        return Self.buildLLMEngine(from: model, temperature: cfg.temperature)
    }

    static func buildLLMEngine(from model: LLMModelDef, temperature: Double) -> any LLMEngine {
        switch model.engine {
        case "ollama":
            return OllamaEngine(config: LLMOllamaConfig(
                baseUrl: model.baseUrl, model: model.model,
                temperature: temperature
            ))
        default:
            return OpenAICompatibleEngine(
                baseUrl: model.baseUrl, apiKey: model.apiKey,
                model: model.model, temperature: temperature, kind: .openai
            )
        }
    }
}
