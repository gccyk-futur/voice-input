import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - 设置页各 Sheet（自 SettingsView.swift 机械拆出，逻辑未改动）

struct PromptPreviewSheet: View {
    let systemPrompt: String
    let userTemplate: String
    let language: String
    let engine: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        let tmpl = PromptTemplate(system: systemPrompt, user: userTemplate)
        let (sys, usr) = tmpl.render(input: VoiceKitLocalization.string("今天天气真好我们出去走走吧"), language: language, engine: engine)

        VStack(alignment: .leading, spacing: 12) {
            Text("提示词预览").font(typography.sectionTitle)
            Text("示例输入：「今天天气真好我们出去走走吧」").font(typography.callout).foregroundStyle(.secondary)

            GroupBox("系统提示词") {
                ScrollView { Text(sys).font(typography.body).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
            GroupBox("用户消息") {
                ScrollView { Text(usr).font(typography.body).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}

// MARK: - LLM 润色测试 Sheet

struct LLMTestSheet: View {
    let llmConfig: LLMConfig
    let language: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale
    @State private var inputText = ""
    @State private var resultText = ""
    @State private var isRunning = false
    @State private var errorMsg: String?

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("测试润色效果").font(typography.sectionTitle)
            Text("输入一段口语文本，测试 LLM 润色后的输出效果").font(typography.callout).foregroundStyle(.secondary)

            // 服务未开启时明确提示：测试仅用于验证配置，不影响实际听写流程
            if !llmConfig.enabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(typography.callout)
                    Text("AI 服务未开启，听写时不会润色。这里的测试会直接调用你选中的模型，用来调试提示词效果。")
                        .font(typography.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            section("输入文本") {
                TextField("在这里输入要测试的口语…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 60)
            }

            HStack {
                Button("开始测试") { runTest() }.disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
                if isRunning { ProgressView().scaleEffect(0.6) }
                Spacer()
                Button("关闭") { dismiss() }
            }

            if let err = errorMsg {
                Text(err).font(typography.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !resultText.isEmpty {
                Divider()
                section("润色结果") {
                    ScrollView {
                        Text(resultText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: .infinity)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(VoiceKitLocalization.string(title)).font(typography.callout).foregroundStyle(.secondary)
            content()
        }
    }

    private func runTest() {
        isRunning = true
        errorMsg = nil
        resultText = ""
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard let model = llmConfig.selectedModel else {
            errorMsg = VoiceKitLocalization.string("请先在「模型管理」中添加并选中一个模型，再测试润色效果")
            isRunning = false
            return
        }

        Task {
            let tmpl = PromptTemplate(system: llmConfig.activePrompt.system, user: llmConfig.activePrompt.user)
            let (sys, usr) = tmpl.render(input: text, language: language, engine: model.engine)
            let engine = AppCoordinator.buildLLMEngine(from: model, temperature: llmConfig.temperature)

            do {
                var acc = ""
                for try await chunk in engine.polish(text, system: sys, userTemplate: usr) {
                    acc += chunk
                }
                await MainActor.run {
                    resultText = acc.isEmpty ? VoiceKitLocalization.string("(返回为空)") : acc
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMsg = VoiceKitLocalization.format("请求失败：%@", error.localizedDescription)
                    isRunning = false
                }
            }
        }
    }
}

// MARK: - 模型编辑器 Sheet（新增 / 编辑）

struct ModelEditorSheet: View {
    let initialModel: LLMModelDef
    let onSave: (LLMModelDef) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale
    @State private var model: LLMModelDef

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    init(model: LLMModelDef, onSave: @escaping (LLMModelDef) -> Void, onCancel: @escaping () -> Void) {
        self.initialModel = model
        self.onSave = onSave
        self.onCancel = onCancel
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(VoiceKitLocalization.string(model.name.isEmpty ? "添加模型" : "编辑模型"))
                .font(typography.sectionTitle)

            section("名称") {
                TextField("例如：我的 DeepSeek", text: $model.name)
                    .textFieldStyle(.roundedBorder)
            }

            section("引擎") {
                Picker("", selection: $model.engine) {
#if APP_STORE
                    Text("云端 API").tag("openai")
#else
                    Text("OpenAI 协议").tag("openai")
#endif
                    Text("Ollama（本地）").tag("ollama")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            section("Base URL") {
                Group {
                    if model.engine == "openai" {
#if APP_STORE
                        TextField("https://your-api.com/v1", text: $model.baseUrl)
#else
                        TextField("https://api.openai.com/v1", text: $model.baseUrl)
#endif
                    } else {
                        TextField("http://localhost:11434", text: $model.baseUrl)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            if model.engine == "openai" {
                section("API Key") {
                    SecureField("sk-...", text: $model.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            section("模型名") {
                Group {
                    if model.engine == "openai" {
#if APP_STORE
                        TextField("your-model-name", text: $model.model)
#else
                        TextField("gpt-4o-mini", text: $model.model)
#endif
                    } else {
                        TextField("qwen2.5:7b", text: $model.model)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            Text(VoiceKitLocalization.format("累计 Token：%lld  ·  使用次数：%lld", model.totalTokens, model.usageCount))
                .font(typography.metadata).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Button("保存") {
                    onSave(model)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          model.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty ||
                          model.model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(VoiceKitLocalization.string(title)).font(typography.callout).foregroundStyle(.secondary)
            content()
        }
    }
}


// MARK: - 提示词编辑器 Sheet（编辑默认/用户预设）

struct PromptEditorSheet: View {
    let initial: SettingsView.PromptEditing
    let onSave: (SettingsView.PromptEditing) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale
    @State private var editing: SettingsView.PromptEditing

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    /// 系统默认提示词：名称固定为「默认」，不显示名称编辑
    private var isSystemDefault: Bool { initial.id.isEmpty }

    init(editing: SettingsView.PromptEditing, onSave: @escaping (SettingsView.PromptEditing) -> Void) {
        self.initial = editing
        self.onSave = onSave
        _editing = State(initialValue: editing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(VoiceKitLocalization.string(isSystemDefault ? "编辑默认提示词" : "编辑提示词"))
                .font(typography.sectionTitle)

            if !isSystemDefault {
                section("名称") {
                    TextField("例如：正式书面语", text: $editing.name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            section("系统提示词") {
                TextEditor(text: $editing.system)
                    .font(typography.body)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }

            section("用户模板") {
                TextEditor(text: $editing.user)
                    .font(typography.body)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }

            Text(VoiceKitLocalization.string("保留 {{input}} 占位符，运行时会替换为原始语音文本。"))
                .font(typography.metadata)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    onSave(editing)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isSystemDefault && editing.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(VoiceKitLocalization.string(title)).font(typography.callout).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 侧栏悬浮面板的背景：NSVisualEffectView 的 .sidebar 材质。
/// withinWindow 混合（与窗口白底混合）= 与 Finder/系统设置侧栏完全同款颜色，
/// 不透桌面、不受壁纸影响；跟随窗口激活态与深浅色外观。
