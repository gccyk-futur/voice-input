import Foundation
import SwiftUI

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
        case .recording, .transcribing, .polishing: stopAndProcess()
        case .ready: confirmPaste()
        }
    }

    func startRecording() {
        guard sessionState == .idle else { return }
        asrText = ""
        llmText = ""
        sessionState = .recording
        statusText = "聆听中…"
        panel.show()

        let engine = resolveASR()
        asrEngine = engine
        Task {
            do {
                try await engine.start(locale: Locale(identifier: configStore.config.asr.system.language)) { [weak self] partial in
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
                sessionState = .ready
                statusText = "完成 · ⌘↵ 粘贴"
            } catch {
                llmText = "（润色失败，使用原文）"
                sessionState = .ready
                statusText = "完成 · ⌘↵ 粘贴"
            }
        } else {
            sessionState = .ready
            statusText = "完成 · ⌘↵ 粘贴"
        }
    }

    func confirmPaste() {
        guard sessionState == .ready else { return }
        let useLLM = configStore.config.llm.enabled && !llmText.isEmpty
        let text = useLLM ? llmText : asrText
        let ok = pasteService.paste(text)
        historyStore.append(HistoryItem(
            asrResult: asrText,
            llmResult: useLLM ? llmText : nil,
            engine: asrEngine?.id ?? "system",
            llmEngine: useLLM ? configStore.config.llm.engine : nil
        ))
        if !ok {
            statusText = "已复制到剪贴板，请手动 ⌘V"
        }
        reset()
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

    func resolveASR() -> any ASREngine {
        SystemDictationEngine()
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
