import Foundation
import SwiftUI
import Speech
import AppKit
import ApplicationServices
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
        configStore.config.asr.engine == "aliyun" ? "阿里云 Fun-ASR" : "系统听写"
    }
    var llmEnabled: Bool { configStore.config.llm.enabled }
    var wsConnected: Bool {
        (asrEngine as? AlibabaASREngine)?.wsConnected ?? false
    }

    init() {
        hotkey.onActivate = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        hotkey.register(hotkeyString: configStore.config.general.hotkey)
        panel.setCoordinator(self)
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
        print("[Coordinator] startRecording: micStatus=\(micStatus.rawValue), speechStatus=\(speechStatus.rawValue)")

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

    /// 显式请求未决定的权限（MainActor）。
    private func requestPendingPermissions(micNeeded: Bool, speechNeeded: Bool) {
        panel.show()
        Task { @MainActor in
            if micNeeded {
                let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
                }
                print("[Coordinator] microphone requestAccess result: \(granted)")
                guard granted else {
                    panel.close()
                    presentPermissionError(micDenied: true, speechDenied: false)
                    return
                }
            }
            if speechNeeded {
                let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
                }
                print("[Coordinator] speech requestAuthorization result: \(granted)")
                guard granted else {
                    panel.close()
                    presentPermissionError(micDenied: false, speechDenied: true)
                    return
                }
            }
            // 全部通过，继续听写流程
            beginRecordingFlow()
        }
    }

    /// 已授权的正常听写启动流程。先解析引擎，Direct 启动。
    private func beginRecordingFlow() {
        targetApp = hotkey.capturedTargetApp ?? NSWorkspace.shared.frontmostApplication
        hotkey.capturedTargetApp = nil
        print("[Coordinator] targetApp=\(targetApp?.localizedName ?? "nil")")
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
                print("[Coordinator] autoStop configured: enabled=\(cfg.silenceAutoStopEnabled) timeout=\(cfg.silenceTimeout)s threshold=\(cfg.silenceThreshold)")
            }
            panel.show(needsActivation: engine.requiresForeground)
            panel.makeKey()
            print("[Coordinator] starting \(engine.displayName), needsActivation=\(engine.requiresForeground)")
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
                print("[Coordinator] engine.start failed: \(error)")
                await MainActor.run {
                    self.sessionState = .idle
                    if let ae = error as? ASRError {
                        switch ae {
                        case .microphoneNotAuthorized:
                            self.statusText = "未授权麦克风：请在 系统设置→隐私与安全性→麦克风 中允许 VoiceMate"
                            self.pasteService.openMicrophoneSettings()
                        case .speechNotAuthorized:
                            self.statusText = "未授权语音识别：请在 系统设置→隐私与安全性→语音识别 中允许 VoiceMate"
                            self.pasteService.openSpeechSettings()
                        default:
                            self.statusText = "听写启动失败：\(error.localizedDescription)"
                        }
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
        print("[Coordinator] stopAndProcess() called, sessionState=\(sessionState), engine=\(asrEngine != nil)")
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
            do {
                for try await chunk in llm.polish(final, system: sys, userTemplate: usr) {
                    llmBuffer += chunk
                }
                stopDisplaySync()
                llmText = llmBuffer
                // 累加 token 统计
                let total = llm.lastPromptTokens + llm.lastCompletionTokens
                if total > 0, !cfg.llm.selectedModelID.isEmpty {
                    configStore.addLLMTokenUsage(modelID: cfg.llm.selectedModelID, tokens: total)
                }
            } catch {
                stopDisplaySync()
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

        // 先关闭面板，让 Accessibility API 能正确拿到目标 App 的焦点元素
        panel.close()

        print("[Paste] confirmPaste target=\(target?.localizedName ?? "nil"), textLen=\(text.count)")

        // 策略1：Accessibility API 直插（主力方案，不动剪贴板、不切换焦点）
        let axService = AccessibilityPasteService.shared
        if axService.isTrusted {
            let inserted = axService.insertText(text)
            if inserted {
                print("[Paste] Accessibility 直插成功")
                finalizeAndRecord(useLLM: useLLM, statusText: nil)
                return
            }
            print("[Paste] Accessibility 直插失败，回退剪贴板方案")
        } else {
            print("[Paste] 辅助功能未授权，使用剪贴板方案")
        }

        // 策略2：剪贴板 + Cmd+V（回退方案）
        guard let target else {
            pasteService.writeClipboardOnly(text)
            finalizeAndRecord(useLLM: useLLM, statusText: "已复制到剪贴板")
            return
        }

        let targetPID = target.processIdentifier
        // .nonactivatingPanel 保证了目标 App 始终在前台，无需 activate+轮询
        pasteService.writeClipboardOnly(text)
        let pasteOK = pasteService.paste(text, to: targetPID)
        print("[Paste] 剪贴板粘贴 result=\(pasteOK)")

        let msg: String? = pasteOK ? nil : "文字已复制到剪贴板（请手动 ⌘V）"
        finalizeAndRecord(useLLM: useLLM, statusText: msg)
    }

    private func finalizeAndRecord(useLLM: Bool, statusText: String?) {
        if let msg = statusText { self.statusText = msg }
        // 引导用户授权辅助功能（授权后可享丝滑直插体验）
        if !AccessibilityPasteService.shared.isTrusted {
            self.statusText = (statusText ?? "") + " 授权辅助功能后可自动输入"
        }
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
        print("[Coordinator] cancel() called, sessionState=\(sessionState), finalizing=\(finalizing)")
        if sessionState == .idle { return }
        if finalizing { return }
        let alreadyStopping = (sessionState == .transcribing || sessionState == .polishing)
        if let engine = asrEngine, !alreadyStopping {
            Task { try? await engine.stop() }
        }
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
            statusText = "未授权麦克风：请在 系统设置→隐私与安全性→麦克风 中允许 VoiceMate"
            pasteService.openMicrophoneSettings()
        } else {
            statusText = "未授权语音识别：请在 系统设置→隐私与安全性→语音识别 中允许 VoiceMate"
            pasteService.openSpeechSettings()
        }
        panel.show()
    }

    // MARK: - 引擎解析（可插拔）

    /// 选择 ASR 引擎：遵从用户设置。
    /// - "system"：SFSpeechRecognizer（稳定，无需前台，自动本地/云端路由）
    /// - "dictation"：DictationTranscriber（原生连续听写，需前台）
    /// - "aliyun"：阿里云 Fun-ASR WebSocket（在线，高精度带标点）
    func resolveASR() async -> any ASREngine {
        print("[Coordinator] resolveASR: engine config = \(configStore.config.asr.engine)")
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
            if let existing = asrEngine, existing.id == "aliyun" {
                return existing
            }
            let cfg = configStore.config.asr.aliyun
            if !cfg.apiKey.isEmpty, !cfg.workspaceId.isEmpty {
                return AlibabaASREngine(
                    apiKey: cfg.apiKey, workspaceId: cfg.workspaceId, region: cfg.region, model: cfg.model,
                    semanticPunctuation: cfg.semanticPunctuation,
                    speechNoiseThreshold: cfg.speechNoiseThreshold,
                    maxSentenceSilence: cfg.maxSentenceSilence,
                    autoStopEnabled: cfg.autoStopEnabled,
                    autoStopTimeout: cfg.autoStopTimeout,
                    autoStopThreshold: Float(cfg.autoStopThreshold)
                )
            }
            print("[Coordinator] Aliyun ASR 未配置 apiKey/workspaceId，自动切回 system")
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

    /// 预建连阿里云引擎：切到阿里云时主动创建，让状态灯能正确显示连接状态。
    func prewarmAliyunEngine() async {
        if asrEngine?.id == "aliyun" { return } // 已有引擎，无需重建
        let cfg = configStore.config.asr.aliyun
        guard !cfg.apiKey.isEmpty, !cfg.workspaceId.isEmpty else { return }
        let engine = AlibabaASREngine(
            apiKey: cfg.apiKey, workspaceId: cfg.workspaceId, region: cfg.region, model: cfg.model,
            semanticPunctuation: cfg.semanticPunctuation,
            speechNoiseThreshold: cfg.speechNoiseThreshold,
            maxSentenceSilence: cfg.maxSentenceSilence,
            autoStopEnabled: cfg.autoStopEnabled,
            autoStopTimeout: cfg.autoStopTimeout,
            autoStopThreshold: Float(cfg.autoStopThreshold)
        )
        self.asrEngine = engine
        print("[Coordinator] 阿里云引擎预建连完成")
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
