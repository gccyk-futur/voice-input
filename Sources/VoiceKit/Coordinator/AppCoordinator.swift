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
        case idle, recording, transcribing, polishing, ready
    }

    var sessionState: SessionState = .idle
    var asrText: String = ""
    var llmText: String = ""
    var statusText: String = "按 ⌘⇧V 开始"
    var audioLevel: Float = 0

    // MARK: - 状态栏展示用的实时状态（@Observable 存储属性，变更驱动 UI 刷新）
    /// 当前选择的 ASR 引擎 id（"system" | "aliyun"）。
    var asrEngineChoice: String = "system"
    /// 阿里云是否已配置 apiKey/workspaceId（决定是否显示双引擎切换）。
    var aliyunConfigured: Bool = false
    /// 阿里云 WebSocket 是否已连接。
    var wsConnected: Bool = false
    /// 阿里云连接状态文字（"已连接" / "连接中…" / "已断开，2.4s 后自动重连"）。
    var wsStatusText: String = "未连接"

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

    // MARK: - Display Sync (LLM 流式文字 → UI 解耦)

    /// LLM token 流写入此 buffer（不触发 UI）。
    private var llmBuffer: String = ""
    /// 按固定间隔将 buffer 同步到 @Observable llmText。
    private var displayTimer: Timer?

    static let shared = AppCoordinator()

    /// 菜单栏状态（供 StatusBarMenu 读取）
    var engineDisplayName: String {
        asrEngineChoice == "aliyun" ? "阿里云 Fun-ASR" : "系统听写"
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
            wsStatusText = "未连接"
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
        guard sessionState == .idle else { return }
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

        // 播放开始提示音
        playSound(named: configStore.config.general.sound.startSound)
        beginRecordingFlow()
    }

    /// 显式请求未决定的权限。
    /// 必须用 Task.detached：AVCaptureDevice / SFSpeechRecognizer
    /// 权限回调在后台线程触发，与 MainActor 隔离的 CheckedContinuation 冲突会在 Debug 构建崩溃。
    private func requestPendingPermissions(micNeeded: Bool, speechNeeded: Bool) {
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
                        self?.panel.close()
                        self?.presentPermissionError(micDenied: true, speechDenied: false)
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
                        self?.panel.close()
                        self?.presentPermissionError(micDenied: false, speechDenied: true)
                    }
                    return
                }
            }
            // 全部通过，继续听写流程
            await MainActor.run { [weak self] in
                self?.beginRecordingFlow()
            }
        }
    }

    /// 已授权的正常听写启动流程。先解析引擎，Direct 启动。
    private func beginRecordingFlow() {
        targetApp = hotkey.capturedTargetApp ?? NSWorkspace.shared.frontmostApplication
        hotkey.capturedTargetApp = nil
        Log.info("[Coordinator] targetApp=\(targetApp?.localizedName ?? "nil")")
        asrText = ""
        llmText = ""
        sessionState = .recording
        statusText = "聆听中…"

        let languageID = configStore.config.asr.system.language
        Task { @MainActor in
            let engine = await self.resolveASR()
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
            startEngine(engine, languageID: languageID)
        }
    }

    /// 启动 ASR 引擎并处理错误。
    private func startEngine(_ engine: any ASREngine, languageID: String) {
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
        // 飞行中失败（麦克风断开、云端连接中断等）：退回 idle 并提示，面板保持可见
        engine.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self, self.sessionState != .idle else { return }
                Log.error("[Coordinator] engine runtime failure: \(error)")
                self.sessionState = .idle
                self.statusText = "听写中断：\(error.localizedDescription)"
            }
        }
        Task {
            do {
                try await engine.start(locale: Locale(identifier: languageID),
                    onPartial: { [weak self] partial in
                        Task { @MainActor in self?.asrText = partial }
                    },
                    onAudioLevel: onLevel,
                    onAutoStop: onSilence
                )
            } catch {
                Log.error("[Coordinator] engine.start failed: \(error)")
                await MainActor.run {
                    self.sessionState = .idle
                    if let ae = error as? ASRError {
                        switch ae {
                        case .microphoneNotAuthorized:
                            self.statusText = "未授权麦克风：请在 系统设置→隐私与安全性→麦克风 中允许 VoiceKit"
                            self.pasteService.openMicrophoneSettings()
                        case .speechNotAuthorized:
                            self.statusText = "未授权语音识别：请在 系统设置→隐私与安全性→语音识别 中允许 VoiceKit"
                            self.pasteService.openSpeechSettings()
                        case .noInputDevice:
                            // 关闭录音面板，只保留弹窗提示，避免"面板+弹窗"同时出现
                            self.panel.close()
                            self.statusText = "未检测到麦克风：请连接麦克风或在 系统设置→声音→输入 中选择输入设备"
                            self.presentErrorAlert(
                                title: "未检测到麦克风",
                                message: "请连接麦克风或在 系统设置→声音→输入 中选择一个输入设备，然后重试。"
                            )
                        default:
                            self.statusText = "听写启动失败：\(error.localizedDescription)"
                        }
                    } else if let aliyunErr = error as? AlibabaASRError {
                        self.statusText = "听写启动失败：\(aliyunErr.localizedDescription)"
                    } else {
                        self.statusText = "听写启动失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// 双通道抢占前台：NSApp.activate（AppKit）+ clickToActivate（CGEvent 模拟点击），
    /// 持续 3s 覆盖 DictationTranscriber 初始化全过程。对抗 iTerm2 等 reclaim 行为。
    func stopAndProcess() {
        Log.info("[Coordinator] stopAndProcess() called, sessionState=\(sessionState), engine=\(asrEngine != nil)")
        guard let engine = asrEngine else { return }
        sessionState = .transcribing
        statusText = "转写中…"
        Task {
            let final = (try? await engine.stop()) ?? self.asrText
            await self.handleFinal(asr: final)
        }
    }

    private func handleFinal(asr final: String) async {
        asrText = final
        // 未识别到任何内容：不进入润色/粘贴流程，直接关闭复位。
        // 既避免"空粘贴"打断用户，也避免空字符串写入/覆盖剪贴板。
        if final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.info("[Coordinator] ASR 结果为空，跳过润色/粘贴")
            await MainActor.run {
                self.reset()
                self.statusText = "未识别到内容"
            }
            return
        }
        let cfg = configStore.config
        if cfg.llm.enabled, let llm = resolveLLM() {
            llmEngine = llm
            sessionState = .polishing
            statusText = "润色中…"
            llmText = ""
            llmBuffer = ""
            startDisplaySync()
            let tmpl = PromptTemplate(system: cfg.llm.prompt.system, user: cfg.llm.prompt.user)
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
            self.playSound(named: self.configStore.config.general.sound.stopSound)
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
            Log.error("[Paste] Accessibility 直插失败，回退剪贴板方案")
        } else {
            Log.info("[Paste] 辅助功能未授权，使用剪贴板方案")
        }
#endif

        // 剪贴板 + Cmd+V
        guard let target else {
            pasteService.writeClipboardOnly(text)
            finalizeAndRecord(useLLM: useLLM, statusText: "已复制到剪贴板")
            return
        }

        let targetPID = target.processIdentifier
        // .nonactivatingPanel 保证了目标 App 始终在前台，无需 activate+轮询
        // paste() 内部会保存原剪贴板 → 写入文字 → ⌘V → 延迟恢复，不要在此预先写入，
        // 否则快照到的将是我们自己写入的内容，用户剪贴板将无法还原。
        let pasteOK = pasteService.paste(text, to: targetPID)
        Log.info("[Paste] 剪贴板粘贴 result=\(pasteOK)")

        let msg: String? = pasteOK ? nil : "文字已复制到剪贴板（请手动 ⌘V）"
        finalizeAndRecord(useLLM: useLLM, statusText: msg)
    }

    private func finalizeAndRecord(useLLM: Bool, statusText: String?) {
        if let msg = statusText { self.statusText = msg }
#if !APP_STORE
        // 引导用户授权辅助功能（授权后可享丝滑直插体验）
        if !AccessibilityPasteService.shared.isTrusted {
            self.statusText = (statusText ?? "") + " 授权辅助功能后可自动输入"
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
    }

    func cancel() {
        Log.info("[Coordinator] cancel() called, sessionState=\(sessionState), finalizing=\(finalizing)")
        if finalizing { return }
        // idle 态（如启动失败后）也必须关面板，否则 Esc/关闭按钮无法收起悬浮窗
        if sessionState != .idle {
            let alreadyStopping = (sessionState == .transcribing || sessionState == .polishing)
            if let engine = asrEngine, !alreadyStopping {
                Task { try? await engine.stop() }
            }
            stopDisplaySync()
        }
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

    private func playSound(named name: String) {
        guard configStore.config.general.sound.enabled else { return }
        NSSound(named: .init(name))?.play()
    }

    private func reset() {
        stopDisplaySync()
        if asrEngine?.id != "aliyun" {
            invalidateASREngine()
        }
        llmEngine = nil
        asrText = ""
        llmText = ""
        sessionState = .idle
        statusText = "按 ⌘⇧V 开始"
        panel.close()
    }

    /// 权限被拒时：在面板显示可读提示并打开对应系统设置页，不进入前台（避免 Dock 闪烁）。
    private func presentPermissionError(micDenied: Bool, speechDenied: Bool) {
        asrText = ""
        llmText = ""
        sessionState = .idle
        if micDenied {
            statusText = "未授权麦克风：请在 系统设置→隐私与安全性→麦克风 中允许 VoiceKit"
            pasteService.openMicrophoneSettings()
        } else {
            statusText = "未授权语音识别：请在 系统设置→隐私与安全性→语音识别 中允许 VoiceKit"
            pasteService.openSpeechSettings()
        }
        panel.show()
    }

    /// 弹出模态错误提示（如未检测到麦克风）。app 为 .accessory 策略，
    /// 弹窗先轻量激活以确保 alert 可见。
    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 引擎解析（可插拔）

    /// 选择 ASR 引擎：遵从用户设置。
    /// - "system"：SFSpeechRecognizer（稳定，无需前台，自动本地/云端路由）
    /// - "dictation"：DictationTranscriber（原生连续听写，需前台）
    /// - "aliyun"：阿里云 Fun-ASR WebSocket（在线，高精度带标点）
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
            fallthrough
        case "aliyun":
            // 复用常驻连接
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
            var corrected = configStore.config
            corrected.asr.engine = "system"
            configStore.update(corrected)
            fallthrough
        default:
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
        wsStatusText = engine.wsConnected ? "已连接" : "未连接"
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
