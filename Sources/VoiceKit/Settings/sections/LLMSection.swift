import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - AI 润色与模型管理（自 SettingsView.swift 机械拆出，逻辑未改动）

extension SettingsView {
    var aiServiceOverviewTab: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("AI 润色")
                            .font(typography.sectionTitle)
                        Spacer()
                        Label(draft.llm.enabled ? "已启用" : "未启用",
                              systemImage: draft.llm.enabled ? "checkmark.circle.fill" : "pause.circle")
                            .font(typography.callout)
                            .foregroundStyle(draft.llm.enabled ? VoiceKitSemanticColor.success : .secondary)
                    }
                    Text("识别完成后，VoiceKit 可以把语音结果发送到你配置的 AI 模型进行整理、补标点和口语改写。AI 润色不会改变语音识别引擎本身。")
                        .font(typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("启用 AI 润色", isOn: llmEnabledBinding)
                }
                .padding(.vertical, 4)
            }

            Section("工作方式") {
                overviewStep("1", title: "先完成语音识别", detail: "语音由当前选择的系统听写或阿里云 Fun-ASR 处理。")
                overviewStep("2", title: "再调用你的模型", detail: "文本只发送到你在模型管理中配置的服务；VoiceKit 没有自己的中转 API。")
                overviewStep("3", title: "最后写回输入位置", detail: "润色结果和原始识别结果都会保留在历史记录中。")
            }

            Section {
                HStack(spacing: 10) {
                    Button("模型管理") { selectedPane = .models }
                        .buttonStyle(.borderedProminent)
                    Button("提示词管理") { selectedPane = .prompts }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    func overviewStep(_ number: String, title: String, detail: String) -> some View {
        let localizedTitle = VoiceKitLocalization.string(title)
        let localizedDetail = VoiceKitLocalization.string(detail)
        return HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(typography.callout.bold())
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedTitle).font(typography.body.bold())
                Text(localizedDetail).font(typography.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 模型管理

    var modelTab: some View {
        Group {
            Section("模型") {
                if draft.llm.models.isEmpty {
                    Text("还没有模型。点击下方「添加模型」配置云端 API 或本地 Ollama 模型。")
                        .font(typography.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(draft.llm.models) { model in
                        modelRow(model)
                    }
                }
                HStack(spacing: 8) {
                    Button("添加模型") { editingModel = Self.makeNewModel() }
                    if !draft.llm.models.isEmpty {
                        Button("批量测试") { runModelBatchTest() }
                            .disabled(isTestingModels)
                    }
                    if isTestingModels {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                        Text("(\(testedModelCount)/\(draft.llm.models.count))")
                            .font(typography.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Text("随机性 (temperature)")
                    Slider(value: $draft.llm.temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", draft.llm.temperature))
                        .font(typography.callout).frame(width: 30)
                }
            } footer: {
                Text("温度越高越随机；越低越稳定。语音润色建议使用 0.3 到 0.7。")
            }

            if let model = draft.llm.selectedModel, model.engine == "openai" {
                Section {
                    Toggle("深度思考 (thinking)", isOn: thinkingBinding)
                } footer: {
                    Text("部分模型支持，启用后先深度推理再输出。请确保所选模型支持此功能。")
                }
            }
        }
    }

    /// 列表行：点击选中当前模型，行内编辑/删除/单测结果
    func modelRow(_ model: LLMModelDef) -> some View {
        let result = modelTestResults[model.id]
        return HStack(alignment: .top, spacing: 10) {
            Button {
                draft.llm.selectedModelID = model.id
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.id == draft.llm.selectedModelID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.id == draft.llm.selectedModelID ? Color.accentColor : VoiceKitSemanticColor.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name.isEmpty ? VoiceKitLocalization.string("未命名模型") : model.name)
                            .font(typography.body)
                            .foregroundStyle(.primary)
                        Text(VoiceKitLocalization.format("%@ · %@ · Token %lld · 使用 %lld 次",
                                                          Self.engineDisplayName(model.engine),
                                                          model.model,
                                                          model.totalTokens,
                                                          model.usageCount))
                            .font(typography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // 测试失败的完整错误独占一行换行展示，不与右侧按钮争抢宽度
                        if let result, !result.success {
                            Text(result.error ?? VoiceKitLocalization.string("未知错误"))
                                .font(typography.metadata)
                                .foregroundStyle(VoiceKitSemanticColor.failure)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(VoiceKitLocalization.format("选择模型 %@", model.name))

            Spacer(minLength: 4)

            if let result {
                if result.success {
                    Text("\(result.latencyMs ?? 0)ms")
                        .font(typography.callout)
                        .foregroundStyle(VoiceKitSemanticColor.success)
                } else {
                    Text(VoiceKitLocalization.string("失败"))
                        .font(typography.callout)
                        .foregroundStyle(VoiceKitSemanticColor.failure)
                        .help(result.error ?? "")
                }
            }

            Button("编辑") { editingModel = model }
                .buttonStyle(.borderless)
            Button(role: .destructive) {
                modelToDelete = model
                showModelDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(VoiceKitLocalization.format("删除模型 %@", model.name))
        }
        .padding(.vertical, 2)
    }

    static func engineDisplayName(_ engine: String) -> String {
#if APP_STORE
        engine == "openai"
            ? VoiceKitLocalization.string("云端 API")
            : VoiceKitLocalization.string("Ollama")
#else
        engine == "openai" ? "OpenAI" : VoiceKitLocalization.string("Ollama")
#endif
    }

    static func makeNewModel() -> LLMModelDef {
#if APP_STORE
        LLMModelDef(name: "", engine: "openai", baseUrl: "", apiKey: "", model: "")
#else
        LLMModelDef(name: "", engine: "openai", baseUrl: "https://api.openai.com/v1", apiKey: "", model: "gpt-4o-mini")
#endif
    }

    func runModelBatchTest() {
        guard !isTestingModels else { return }
        isTestingModels = true
        testedModelCount = 0
        modelTestResults = [:]
        let models = draft.llm.models
        let temperature = draft.llm.temperature

        Task {
            for model in models {
                let start = Date()
                let engine = AppCoordinator.buildLLMEngine(from: model, temperature: temperature)
                do {
                    var acc = ""
                    let stream = engine.polish("ping", system: VoiceKitLocalization.string("回复 OK"), userTemplate: VoiceKitLocalization.string("回复 OK"))
                    for try await chunk in stream { acc += chunk }
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    let tokens = engine.lastPromptTokens + engine.lastCompletionTokens
                    await MainActor.run {
                        modelTestResults[model.id] = ModelTestResult(success: true, latencyMs: elapsed, tokensUsed: tokens, error: nil)
                        testedModelCount += 1
                        if tokens > 0 {
                            ConfigStore.shared.addLLMTokenUsage(modelID: model.id, tokens: tokens)
                        }
                    }
                } catch {
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    await MainActor.run {
                        modelTestResults[model.id] = ModelTestResult(success: false, latencyMs: elapsed, tokensUsed: 0, error: error.localizedDescription)
                        testedModelCount += 1
                    }
                }
            }
            await MainActor.run { isTestingModels = false }
        }
    }

    struct ModelTestResult {
        var success: Bool
        var latencyMs: Int?
        var tokensUsed: Int
        var error: String?
    }

    var thinkingBinding: Binding<Bool> {
        Binding(
            get: {
                guard let idx = draft.llm.models.firstIndex(where: { $0.id == draft.llm.selectedModelID }) else { return false }
                return draft.llm.models[idx].model.contains("thinking") || draft.llm.models[idx].model.contains("qwq")
            },
            set: { value in
                guard let idx = draft.llm.models.firstIndex(where: { $0.id == draft.llm.selectedModelID }) else { return }
                if value {
                    if !draft.llm.models[idx].model.contains("thinking") && !draft.llm.models[idx].model.contains("qwq") {
                        draft.llm.models[idx].model += "-thinking"
                    }
                } else {
                    draft.llm.models[idx].model = draft.llm.models[idx].model
                        .replacingOccurrences(of: "-thinking", with: "")
                        .replacingOccurrences(of: "qwq-plus", with: "qwen-plus")
                }
            }
        )
    }

    // MARK: - 提示词管理

    var promptTab: some View {
        Group {
            Section {
                // 系统默认：固定第一条，可编辑不可删除
                promptRow(
                    id: "",
                    name: "默认",
                    subtitle: String(draft.llm.prompt.user.prefix(40)),
                    deletable: false
                )
                ForEach(draft.llm.prompts) { preset in
                    promptRow(
                        id: preset.id,
                        name: preset.name,
                        subtitle: String(preset.user.prefix(40)),
                        deletable: true,
                        preset: preset
                    )
                }
                HStack(spacing: 8) {
                    Button("新建（复制当前）") { addPromptPreset() }
                    Button("从预设库导入…") { showPresetGallery = true }
                    Spacer()
                    Button("预览") { showPromptPreview = true }
                    Button("测试润色效果") { showLLMTest = true }
                }
            } header: {
                Text("提示词")
            } footer: {
                Text("「默认」是系统内置提示词，可编辑但不可删除；新建会以当前选中的提示词为起点。预览和测试作用于当前选中的提示词。")
            }
        }
    }

    /// 列表行：点击选中当前提示词；行内编辑/删除
    func promptRow(id: String, name: String, subtitle: String, deletable: Bool, preset: LLMPromptPreset? = nil) -> some View {
        HStack(spacing: 10) {
            Button {
                draft.llm.selectedPromptID = id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: draft.llm.selectedPromptID == id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(draft.llm.selectedPromptID == id ? Color.accentColor : VoiceKitSemanticColor.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(deletable ? name : VoiceKitLocalization.string("默认"))
                                .font(typography.body)
                                .foregroundStyle(.primary)
                            if !deletable {
                                Text("系统")
                                    .font(typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(subtitle)
                            .font(typography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(VoiceKitLocalization.format("选择提示词 %@", deletable ? name : VoiceKitLocalization.string("默认")))

            Spacer(minLength: 4)

            Button("编辑") {
                if let preset {
                    editingPrompt = PromptEditing(id: preset.id, name: preset.name, system: preset.system, user: preset.user)
                } else {
                    editingPrompt = PromptEditing(id: "", name: "默认", system: draft.llm.prompt.system, user: draft.llm.prompt.user)
                }
            }
            .buttonStyle(.borderless)

            if deletable, let preset {
                Button(role: .destructive) {
                    promptToDelete = preset
                    showPromptDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(VoiceKitLocalization.format("删除提示词 %@", name))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 提示词预设操作

    /// 以当前选中的提示词（含系统默认）为模板复制一份新的
    func addPromptPreset() {
        let base = draft.llm.activePrompt
        let new = LLMPromptPreset(
            name: VoiceKitLocalization.format("提示词 %lld", draft.llm.prompts.count + 1),
            system: base.system,
            user: base.user
        )
        draft.llm.prompts.append(new)
        draft.llm.selectedPromptID = new.id
    }

    /// 编辑上下文：id 为空字符串表示系统默认提示词（名称固定、不可删除）
    struct PromptEditing: Identifiable {
        var id: String
        var name: String
        var system: String
        var user: String
    }

    // MARK: - 权限

}
