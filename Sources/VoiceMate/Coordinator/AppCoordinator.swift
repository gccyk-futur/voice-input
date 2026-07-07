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
            NSApp.activate(ignoringOtherApps: true)
            panel.show()
            panel.makeKey()
            print("[Coordinator] starting \(engine.displayName)")
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
        // 关闭面板，粘贴完成后 reset() 会清理
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
        print("[Coordinator] cancel() called, sessionState=\(sessionState), finalizing=\(finalizing)")
        if sessionState == .idle { return }
        if finalizing { return }
        let alreadyStopping = (sessionState == .transcribing || sessionState == .polishing)
        if let engine = asrEngine, !alreadyStopping {
            Task { try? await engine.stop() }
        }
        reset()
        // 归还焦点给之前的应用
        if let t = targetApp { t.activate() }
        targetApp = nil
    }

    private func reset() {
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
                    apiKey: cfg.apiKey, workspaceId: cfg.workspaceId, model: cfg.model,
                    semanticPunctuation: cfg.semanticPunctuation,
                    speechNoiseThreshold: cfg.speechNoiseThreshold,
                    maxSentenceSilence: cfg.maxSentenceSilence,
                    autoStopEnabled: cfg.autoStopEnabled,
                    autoStopTimeout: cfg.autoStopTimeout,
                    autoStopThreshold: Float(cfg.autoStopThreshold)
                )
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
            if #available(macOS 26, *),
               await DictationTranscriber.supportedLocale(equivalentTo: loc) != nil {
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
