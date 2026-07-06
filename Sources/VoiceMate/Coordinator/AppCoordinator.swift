import Foundation
import SwiftUI
import Speech
import AppKit
import ApplicationServices

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
        // 使用 HotkeyManager 在 Carbon 回调第一时间（任何激活操作之前）捕获的目标 app。
        // 回退到当前 frontmostApplication 以防万一。
        targetApp = hotkey.capturedTargetApp ?? NSWorkspace.shared.frontmostApplication
        hotkey.capturedTargetApp = nil
        print("[Coordinator] targetApp=\(targetApp?.localizedName ?? "nil"), isActive=\(NSApp.isActive)")
        asrText = ""
        llmText = ""
        sessionState = .recording
        statusText = "聆听中…"
        // HotkeyManager 的 Carbon 回调已在用户事件上下文中同步执行了
        // TransformProcessType + SetFrontProcess + setActivationPolicy + NSApp.activate。
        // 此处 enterForeground 做最终兜底：若 app 已在前台则 TransformProcessType 返回 -50（无害）。
        enterForeground()
        panel.show()
        print("[Coordinator] panel shown, isActive=\(NSApp.isActive), isKey=\(panel.isKeyWindow)")
        panel.clickToActivate()
        // 某些 app（如 iTerm2）失去焦点后会立即 reclaim 激活。定期重新 click 来维持激活，
        // 直到 DictationTranscriber 完全启动。
        scheduleActivationPersistence()

        let languageID = configStore.config.asr.system.language
        activationFired = false
        waitForActivation { [weak self] in
            guard let self, self.sessionState == .recording else { return }
            // 激活后把面板提到最前并设 key（show() 时 isActive=false，orderFrontRegardless 被忽略）
            self.panel.orderFront()
            print("[Coordinator] panel ordered front after activation, isActive=\(NSApp.isActive), isKey=\(self.panel.isKeyWindow)")
            print("[Coordinator] activation confirmed, isActive=\(NSApp.isActive), isKey=\(self.panel.isKeyWindow), starting engine")
            Task {
                let engine = await self.resolveASR()
                await MainActor.run { self.asrEngine = engine }
                do {
                    try await engine.start(locale: Locale(identifier: languageID)) { [weak self] partial in
                        Task { @MainActor in self?.asrText = partial }
                    }
                } catch {
                    await MainActor.run {
                        self.exitForeground()
                        self.sessionState = .idle
                        self.statusText = "听写启动失败：\(error.localizedDescription)"
                        self.panel.close()
                    }
                }
            }
        }
    }

    /// 定期重新发送 clickToActivate，持续 0.6s。对抗 iTerm2 等 app 在失去焦点后立即 reclaim 激活的行为。
    private func scheduleActivationPersistence() {
        func reclick(at delay: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.sessionState == .recording else { return }
                self.panel.clickToActivate()
                print("[Coordinator] re-clickToActivate @ \(delay)s, isActive=\(NSApp.isActive)")
            }
        }
        reclick(at: 0.08)
        reclick(at: 0.20)
        reclick(at: 0.35)
        reclick(at: 0.55)
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
        // 到达就绪态：自动粘贴到当前光标并关闭面板（系统听写式体验）。
        // raw/润色文本在此前始终留在 app 内，只有这一步才离开。
        await MainActor.run { self.confirmPaste() }
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
        if sessionState == .idle { return }
        // 正在自动粘贴收尾：忽略面板关闭触发的 cancel，避免复位打断粘贴流程。
        if finalizing { return }
        if let engine = asrEngine {
            Task { try? await engine.stop() }
        }
        reset()
    }

    private func reset() {
        asrEngine = nil
        llmEngine = nil
        asrText = ""
        llmText = ""
        sessionState = .idle
        statusText = "按 ⌘⇧V 开始"
        panel.close()
        exitForeground()
    }

    /// 听写期间将 agent 进程提升为前台应用。Dock 图标显示是 TransformProcessType 的必然副作用，
    /// 听写结束后 exitForeground 会将其隐藏。DictationTranscriber 需要进程处于前台状态。
    private func enterForeground() {
        guard !foregroundedForDictation else { return }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let tptOK = TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToForegroundApplication)) == noErr
        NSApp.setActivationPolicy(.regular)
        print("[Coordinator] enterForeground: TransformProcessType=\(tptOK), isActive=\(NSApp.isActive)")
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

    /// 选择 ASR 引擎：优先使用本地连续听写（DictationTranscriber，复用系统已下载模型，
    /// 与系统「听写」同源），仅当本机不支持该语言时才回退到 SFSpeechRecognizer（服务器）。
    func resolveASR() async -> any ASREngine {
        let raw = configStore.config.asr.system.language
        let loc = Locale(identifier: raw)
        if await DictationTranscriber.supportedLocale(equivalentTo: loc) != nil {
            return SystemDictationEngine()
        }
        return LegacyDictationEngine()
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
