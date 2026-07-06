import Foundation
import SwiftUI
import Speech
import AppKit

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
        // 记下当前前台的目标 app（文字应插入它的输入框）。on-device 听写需要本 app 处于
        // 激活状态才能出结果，因此下面会激活本 app；停止时再把焦点还给 targetApp。
        targetApp = NSWorkspace.shared.frontmostApplication
        asrText = ""
        llmText = ""
        sessionState = .recording
        statusText = "聆听中…"
        // 激活本 app 以驱动 on-device 听写（菜单栏 agent 默认不激活，会导致识别不开始）。
        NSApp.activate(ignoringOtherApps: true)
        panel.show()

        let languageID = configStore.config.asr.system.language
        Task {
            let engine = await resolveASR()
            await MainActor.run { self.asrEngine = engine }
            do {
                try await engine.start(locale: Locale(identifier: languageID)) { [weak self] partial in
                    Task { @MainActor in self?.asrText = partial }
                }
            } catch {
                await MainActor.run {
                    self.sessionState = .idle
                    self.statusText = "听写启动失败：\(error.localizedDescription)"
                    self.panel.close()
                }
            }
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
        let useLLM = configStore.config.llm.enabled && !llmText.isEmpty
        let text = useLLM ? llmText : asrText
        // 识别期间本 app 被激活以驱动 on-device 听写；停止时先把焦点还给目标 app，
        // 再在其光标处插入文本（否则会粘到我们自己的面板、且清空目标原文）。
        if let target = targetApp {
            target.activate(options: .activateIgnoringOtherApps)
        }
        targetApp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let ok = self.pasteService.paste(text)
            if !ok {
                // 粘贴失败：未授权辅助功能时引导开启；文本已在剪贴板，可手动 ⌘V。
                if !self.pasteService.isTrusted {
                    self.pasteService.openAccessibilitySettings()
                    self.statusText = "请到 系统设置→隐私与安全性→辅助功能 允许 VoiceMate（已复制，可手动 ⌘V）"
                } else {
                    self.statusText = "已复制到剪贴板，请手动 ⌘V"
                }
                return
            }
            self.historyStore.append(HistoryItem(
                asrResult: self.asrText,
                llmResult: useLLM ? self.llmText : nil,
                engine: self.asrEngine?.id ?? "system",
                llmEngine: useLLM ? self.configStore.config.llm.engine : nil
            ))
            self.reset()
        }
    }

    func cancel() {
        if sessionState == .idle { return }
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
        default: return nil
        }
    }
}
