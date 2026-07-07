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

    private let configStore = ConfigStore.shared
    private let historyStore = HistoryStore.shared
    private let pasteService = PasteService.shared
    private let hotkey = HotkeyManager.shared
    private let panel = FloatingPanelController()

    private var asrEngine: (any ASREngine)?
    private var llmEngine: (any LLMEngine)?
    /// 识别开始时前台的目标 app（文字应插入它的输入框）；停止时把焦点还给它。
    private var targetApp: NSRunningApplication?
    /// 收尾标记：自动粘贴流程进行中。此时面板关闭触发的 cancel 应被忽略，避免双重复位。
    private var finalizing = false
    /// 听写期间是否把 app 从 agent(.accessory) 临时切成了前台(.regular)。
    /// LSUIElement(agent) 应用调用 NSApp.activate 往往无法真正置前，on-device 听写 daemon
    /// 只在 app 真正处于前台激活态时才回传结果（否则必须手动点面板才开始识别）。
    private var foregroundedForDictation = false
    /// waitForActivation 的"只触发一次"守卫：避免多个定时器重复启动引擎。
    private var activationFired = false

    static let shared = AppCoordinator()

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
        NSSound(named: .init("Tink"))?.play()
        beginRecordingFlow()
    }

    /// 显式请求未决定的权限（MainActor）。先进入前台 + 显示面板以提供 UI 上下文，
    /// 等 WindowServer 确认激活后再调 requestAccess——TCC daemon 仅在 app 为
    /// 前台激活态时才弹出对话框，否则静默返回 false。全部通过后继续听写流程。
    private func requestPendingPermissions(micNeeded: Bool, speechNeeded: Bool) {
        enterForeground()
        panel.show()
        // 轮询等待 NSApp.isActive，超时 1s。TCC 对话框必须在前台激活态下发起。
        Task { @MainActor in
            for _ in 0..<20 {
                if NSApp.isActive { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            print("[Coordinator] requestPermissions: isActive=\(NSApp.isActive)")
            if micNeeded {
                let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
                }
                print("[Coordinator] microphone requestAccess result: \(granted)")
                guard granted else {
                    exitForeground()
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
                    exitForeground()
                    panel.close()
                    presentPermissionError(micDenied: false, speechDenied: true)
                    return
                }
            }
            // 全部通过，继续听写流程
            beginRecordingFlow()
        }
    }

    /// 已授权的正常听写启动流程。先解析引擎，再决定是否需要前台激活。
    private func beginRecordingFlow() {
        targetApp = hotkey.capturedTargetApp ?? NSWorkspace.shared.frontmostApplication
        hotkey.capturedTargetApp = nil
        print("[Coordinator] targetApp=\(targetApp?.localizedName ?? "nil"), isActive=\(NSApp.isActive)")
        asrText = ""
        llmText = ""
        sessionState = .recording
        statusText = "聆听中…"

        let languageID = configStore.config.asr.system.language
        Task {
            let engine = await self.resolveASR()
            await MainActor.run { self.asrEngine = engine }

            if engine.requiresForeground {
                // DictationTranscriber：必须前台，走完整激活舞
                if !foregroundedForDictation {
                    enterForeground()
                    panel.show()
                }
                panel.clickToActivate()
                scheduleActivationPersistence()
                activationFired = false
                waitForActivation { [weak self] in
                    guard let self, self.sessionState == .recording else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel.orderFront()
                    self.panel.makeKey()
                    print("[Coordinator] activation confirmed, starting DictationTranscriber engine")
                    self.startEngine(engine, languageID: languageID)
                }
            } else {
                // 不需要前台的引擎（SFSpeechRecognizer / Alibaba Fun-ASR）：面板浮在最上、不抢焦点
                panel.show()
                panel.makeKey()
                print("[Coordinator] starting \(engine.displayName) engine, no activation needed")
                startEngine(engine, languageID: languageID)
            }
        }
    }

    /// 启动 ASR 引擎并处理错误。
    private func startEngine(_ engine: any ASREngine, languageID: String) {
        Task {
            do {
                try await engine.start(locale: Locale(identifier: languageID)) { [weak self] partial in
                    Task { @MainActor in self?.asrText = partial }
                }
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
    private func scheduleActivationPersistence() {
        // 前 1s 密集对抗目标 app 的 reclaim（每 80-150ms），后 2s 稀疏保活（每 400ms）
        let schedule: [Double] = [0.08, 0.20, 0.35, 0.55, 0.75, 1.0, 1.4, 1.8, 2.3, 2.8]
        for delay in schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.sessionState == .recording else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.panel.clickToActivate()
                print("[Coordinator] re-activate @ \(delay)s, isActive=\(NSApp.isActive)")
            }
        }
    }

    /// 等待 app 激活（NSApp.isActive == true），超时 0.8s 后强制执行。
    /// 只触发一次 action，避免多个定时器重复启动引擎。
    private func waitForActivation(then action: @escaping @MainActor () -> Void) {
        if NSApp.isActive {
            activationFired = true
            action()
            return
        }
        func fireOnce(_ label: String) {
            guard !activationFired else { return }
            activationFired = true
            print("[Coordinator] isActive became true (\(label)), starting engine")
            action()
        }
        func fireTimeout(_ label: String) {
            guard !activationFired else { return }
            activationFired = true
            print("[Coordinator] activation timeout (\(label)), isActive=\(NSApp.isActive), starting engine anyway")
            action()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if NSApp.isActive { fireOnce("@0.05s") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if NSApp.isActive { fireOnce("@0.15s") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSApp.isActive { fireOnce("@0.4s") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if NSApp.isActive { fireOnce("@0.8s") }
            else { fireTimeout("@0.8s") }
        }
    }

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
            let tmpl = PromptTemplate(system: cfg.llm.prompt.system, user: cfg.llm.prompt.user)
            let (sys, usr) = tmpl.render(input: final, language: cfg.asr.system.language, engine: cfg.llm.engine)
            var acc = ""
            do {
                for try await chunk in llm.polish(final, system: sys, userTemplate: usr) {
                    acc += chunk
                    llmText = acc
                }
            } catch {
                // 润色失败回退原文（不要把错误提示粘出去）
                llmText = final
            }
            sessionState = .ready
        } else {
            sessionState = .ready
        }
        // 到达就绪态：自动粘贴
        await MainActor.run {
            NSSound(named: .init("Purr"))?.play()
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
        // 关闭面板但**不** exitForeground。粘贴需要 VoiceMate 保持前台状态，
        // 否则 agent 应用的 CGEvent HID 投递可能被系统限制。reset() 中会 exitForeground。
        panel.close()
        print("[Paste] confirmPaste target=\(target?.localizedName ?? "nil"), textLen=\(text.count), isTrusted=\(pasteService.isTrusted)")

        guard let target else {
            pasteService.writeClipboardOnly(text)
            reset()
            finalizing = false
            statusText = "已复制到剪贴板"
            return
        }

        let targetPID = target.processIdentifier
        target.activate()
        waitForTargetActivation(target: target) { [weak self] ok in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication
            print("[Paste] target activation result=\(ok), frontmost=\(front?.localizedName ?? "nil")")
            // 0.3s 延迟：等待目标 app 内部文本框重新获得键盘焦点。
            // 仅 activate 把 app 推到前台不够——文本框聚焦是异步的。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                // 优先通过 PID 直送 ⌘V（无需目标在前台），回退到 HID 级别事件。
                let pasteOK = self.pasteService.paste(text, to: targetPID)
                print("[Paste] primary paste (postToPid) result=\(pasteOK)")
                if pasteOK {
                    self.historyStore.append(HistoryItem(
                        asrResult: self.asrText,
                        llmResult: useLLM ? self.llmText : nil,
                        engine: self.asrEngine?.id ?? "system",
                        llmEngine: useLLM ? self.configStore.config.llm.engine : nil
                    ))
                } else {
                    // postToPid 失败：用 HID 事件做二次尝试
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let retry = self.pasteService.paste(text)
                        print("[Paste] fallback paste (HID) result=\(retry)")
                    }
                    if !self.pasteService.isTrusted {
                        self.pasteService.openAccessibilitySettings()
                        self.statusText = "未授权辅助功能（签名不匹配），请用 Xcode Run 构建并在 系统设置→隐私与安全性→辅助功能 中重新授权。文字已复制到剪贴板。"
                    } else {
                        self.statusText = "已复制到剪贴板，请手动 ⌘V"
                    }
                }
                self.reset()
                self.finalizing = false
            }
        }
    }

    /// 轮询等待目标 app 回到前台。
    private func waitForTargetActivation(target: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(0.6)
        func check(tick: Int) {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier == target.bundleIdentifier {
                completion(true)
                return
            }
            if Date() > deadline {
                completion(false)
                return
            }
            target.activate()
            let delay = tick <= 2 ? 0.08 : 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check(tick: tick + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(tick: 0) }
    }

    func cancel() {
        print("[Coordinator] cancel() called, sessionState=\(sessionState), finalizing=\(finalizing), foregrounded=\(foregroundedForDictation)")
        if sessionState == .idle { return }
        if finalizing { return }
        // 已在 stopAndProcess 中：不重复 stop，直接 reset
        let alreadyStopping = (sessionState == .transcribing || sessionState == .polishing)
        if let engine = asrEngine, !alreadyStopping {
            Task { try? await engine.stop() }
        }
        reset()
        exitForeground()
    }

    private func reset() {
        // 阿里云引擎保持常驻连接，不销毁
        if asrEngine?.id != "aliyun" {
            asrEngine = nil
        }
        llmEngine = nil
        asrText = ""
        llmText = ""
        sessionState = .idle
        statusText = "按 ⌘⇧V 开始"
        panel.close()
        exitForeground()
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

    /// 听写期间将 agent 进程提升为前台应用。Dock 图标显示是 TransformProcessType 的必然副作用，
    /// 听写结束后 exitForeground 会将其隐藏。DictationTranscriber 需要进程处于前台状态。
    private func enterForeground() {
        guard !foregroundedForDictation else { return }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToForegroundApplication))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        print("[Coordinator] enterForeground: isActive=\(NSApp.isActive)")
        foregroundedForDictation = true
    }

    private func exitForeground() {
        guard foregroundedForDictation else { return }
        NSApp.setActivationPolicy(.accessory)
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToUIElementApplication))
        print("[Coordinator] exitForeground → accessory")
        foregroundedForDictation = false
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
            let raw = configStore.config.asr.system.language
            let loc = Locale(identifier: raw)
            if await DictationTranscriber.supportedLocale(equivalentTo: loc) != nil {
                return SystemDictationEngine()
            }
            fallthrough // 回退到 system
        case "aliyun":
            // 复用常驻连接
            if let existing = asrEngine, existing.id == "aliyun" {
                return existing
            }
            let cfg = configStore.config.asr.aliyun
            if !cfg.apiKey.isEmpty, !cfg.workspaceId.isEmpty {
                return AlibabaASREngine(apiKey: cfg.apiKey, workspaceId: cfg.workspaceId, model: cfg.model)
            }
            print("[Coordinator] Aliyun ASR 未配置 apiKey/workspaceId，回退到 system")
            fallthrough
        default:
            let raw = configStore.config.asr.system.language
            let loc = Locale(identifier: raw)
            let recognizer = SFSpeechRecognizer(locale: loc)
            if let recognizer, recognizer.isAvailable {
                return LegacyDictationEngine()
            }
            if await DictationTranscriber.supportedLocale(equivalentTo: loc) != nil {
                return SystemDictationEngine()
            }
            return LegacyDictationEngine()
        }
    }

    func resolveLLM() -> (any LLMEngine)? {
        let cfg = configStore.config.llm
        switch cfg.engine {
        case "ollama": return OllamaEngine(config: cfg.ollama)
        case "openai": return OpenAICompatibleEngine(baseUrl: cfg.openai.baseUrl, apiKey: cfg.openai.apiKey, model: cfg.openai.model, temperature: cfg.openai.temperature, kind: .openai)
        case "deepseek": return OpenAICompatibleEngine(baseUrl: cfg.deepseek.baseUrl, apiKey: cfg.deepseek.apiKey, model: cfg.deepseek.model, temperature: cfg.deepseek.temperature, kind: .deepseek)
        case "custom": return OpenAICompatibleEngine(baseUrl: cfg.custom.baseUrl, apiKey: cfg.custom.apiKey, model: cfg.custom.model, temperature: cfg.custom.temperature, kind: .custom)
        case "claude": return ClaudeEngine(baseUrl: cfg.claude.baseUrl, apiKey: cfg.claude.apiKey, model: cfg.claude.model, temperature: cfg.claude.temperature)
        default: return nil
        }
    }
}
