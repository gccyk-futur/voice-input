import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

private enum ContactInfo {
    static let email = "voicekit@ckai.me"
    static let website = "ckai.me/voice-kit"
    static let github = "github.com/gccyk-futur/voice-input"
}

struct SettingsView: View {
    var onDone: () -> Void = {}
    var onTabChange: (Int) -> Void = { _ in }

    @State private var draft: AppConfig = ConfigStore.shared.config
    /// 打开设置时的原始配置，用于判断是否有未保存变更
    @State private var originalConfig: AppConfig = ConfigStore.shared.config
    @AppStorage("voicekit.settings.selectedPane") private var selectedPaneRawValue = SettingsPane.general.rawValue
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @AppStorage("voicekit.ui.appearance") private var appearanceRawValue = VoiceKitAppearance.system.rawValue
    @State private var selectedPane = SettingsPane.general
    @State private var showAPIKey = false
    @State private var permissionRefreshID = UUID()
    @State private var postEventRequestAttempted = false
    @State private var restartRequested = false

    // 保存校验
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    // 提示词预览
    @State private var showPromptPreview = false

    // LLM 润色测试
    @State private var showLLMTest = false

    // 模型管理（内联列表）
    @State private var editingModel: LLMModelDef?
    @State private var showModelDeleteConfirm = false
    @State private var modelToDelete: LLMModelDef?
    @State private var modelTestResults: [String: ModelTestResult] = [:]
    @State private var isTestingModels = false
    @State private var testedModelCount = 0

    // 提示词
    @State private var showPromptDeleteConfirm = false
    @State private var promptToDelete: LLMPromptPreset?
    @State private var editingPrompt: PromptEditing?

    // 恢复默认
    @State private var showResetConfirm = false

    @State private var showDiscardAlert = false

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
                    .padding(.leading, pane.isSubpane ? 16 : 0)
            }
            .listStyle(.sidebar)
            .font(typography.body)
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if hasChanges {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.circle.fill")
                        Text("有未保存的变更")
                    }
                    .font(typography.callout)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08))
                }

                // 内容列限宽居中，标题与分组卡片左缘对齐（系统设置的版式）
                VStack(alignment: .leading, spacing: 0) {
                    paneHeader
                        .padding(.leading, 20)
                        .padding(.top, 16)

                    Form {
                        paneContent
                    }
                    .formStyle(.grouped)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)

                Divider()

                // 带显式保存的偏好设置窗口惯例：操作按钮固定在右下角
                HStack(spacing: 10) {
                    Spacer()
                    Button("关闭") { closeSettings() }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") { save() }
                        .disabled(!hasChanges)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .font(typography.body)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 580)
        .voiceKitTextScale(selectedTextScale)
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            selectedPane = SettingsPane.restored(from: selectedPaneRawValue)
            onTabChange(selectedPane.index)
        }
        .onChange(of: selectedPane) { _, newPane in
            selectedPaneRawValue = newPane.rawValue
            onTabChange(newPane.index)
        }
        .alert("保存失败", isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
        .alert("放弃未保存的更改？", isPresented: $showDiscardAlert) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃更改", role: .destructive) { onDone() }
        } message: {
            Text("关闭后，尚未保存的设置将不会生效。")
        }
        .sheet(isPresented: $showPromptPreview) {
            PromptPreviewSheet(systemPrompt: draft.llm.activePrompt.system,
                               userTemplate: draft.llm.activePrompt.user,
                               language: draft.asr.system.language,
                               engine: draft.llm.selectedModel?.engine ?? "openai")
        }
        .sheet(isPresented: $showLLMTest) {
            LLMTestSheet(llmConfig: draft.llm, language: draft.asr.system.language)
        }
        .sheet(item: $editingModel) { model in
            ModelEditorSheet(
                model: model,
                onSave: { saved in
                    if let idx = draft.llm.models.firstIndex(where: { $0.id == saved.id }) {
                        draft.llm.models[idx] = saved
                    } else {
                        draft.llm.models.append(saved)
                        if draft.llm.selectedModelID.isEmpty { draft.llm.selectedModelID = saved.id }
                    }
                    editingModel = nil
                },
                onCancel: { editingModel = nil }
            )
        }
        .alert("删除模型？", isPresented: $showModelDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let m = modelToDelete {
                    draft.llm.models.removeAll { $0.id == m.id }
                    if draft.llm.selectedModelID == m.id {
                        draft.llm.selectedModelID = draft.llm.models.first?.id ?? ""
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(modelToDelete?.name ?? "")」吗？此操作不可撤销。")
        }
        .alert("删除提示词？", isPresented: $showPromptDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let p = promptToDelete {
                    draft.llm.prompts.removeAll { $0.id == p.id }
                    if draft.llm.selectedPromptID == p.id {
                        draft.llm.selectedPromptID = ""
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(promptToDelete?.name ?? "")」吗？删除后将切回系统默认提示词。")
        }
        .alert("恢复默认设置？", isPresented: $showResetConfirm) {
            Button("恢复默认", role: .destructive) {
                draft = .default
                // 外观/文字大小是即时生效的 UI 偏好，一并复位
                appearanceRawValue = VoiceKitAppearance.system.rawValue
                textScaleRawValue = VoiceKitTextScale.system.rawValue
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("热键、声音、语音引擎、模型（含 API Key）和提示词都会恢复出厂默认。恢复后点击右下角「保存」生效，直接关闭窗口可放弃。")
        }
        .sheet(item: $editingPrompt) { editing in
            PromptEditorSheet(editing: editing) { saved in
                if saved.id.isEmpty {
                    // 系统默认提示词：写回 llm.prompt，名称固定
                    draft.llm.prompt.system = saved.system
                    draft.llm.prompt.user = saved.user
                } else if let idx = draft.llm.prompts.firstIndex(where: { $0.id == saved.id }) {
                    draft.llm.prompts[idx].name = saved.name
                    draft.llm.prompts[idx].system = saved.system
                    draft.llm.prompts[idx].user = saved.user
                } else {
                    draft.llm.prompts.append(LLMPromptPreset(id: saved.id, name: saved.name, system: saved.system, user: saved.user))
                }
                editingPrompt = nil
            }
        }
    }

    private var selectedTextScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: selectedTextScale)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general: generalTab
        case .input: asrTab
        case .services: aiServiceOverviewTab
        case .models: modelTab
        case .prompts: promptTab
        case .permissions: permissionTab
        case .privacy: privacyTab
        case .about: aboutTab
        }
    }

    // MARK: - 面板标题

    /// 每个设置面板的标题与一句话说明，切换侧边栏时同步更新，
    /// 让用户始终知道自己处于哪个设置域（HIG：清晰的位置反馈）。
    @ViewBuilder
    private var paneHeader: some View {
        if selectedPane != .about {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedPane.title)
                    .font(typography.title)
                Text(selectedPane.description)
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - 声音列表

    private static let systemSounds: [(String, String)] = [
        ("Basso", "Basso"), ("Blow", "Blow"), ("Bottle", "Bottle"),
        ("Frog", "Frog"), ("Funk", "Funk"), ("Glass", "Glass"),
        ("Hero", "Hero"), ("Morse", "Morse"), ("Ping", "Ping"),
        ("Pop", "Pop"), ("Purr", "Purr"), ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"), ("Tink", "Tink"),
    ]

    // MARK: - 常规

    private var generalTab: some View {
        Group {
            Section("全局热键") {
                HotkeyRecorder(hotkeyString: $draft.general.hotkey)
                    .frame(height: 26)
            }

            Section("启动") {
                Toggle("登录时启动", isOn: $draft.general.launchAtStartup)
                Toggle("启动时显示设置窗口", isOn: $draft.general.showSettingsOnLaunch)
            }

            Section {
                Picker("保留历史", selection: $draft.general.maxHistoryCount) {
                    Text("20 条").tag(20); Text("50 条").tag(50)
                    Text("100 条").tag(100); Text("200 条").tag(200)
                }
            }

            Section {
                Picker("外观", selection: $appearanceRawValue) {
                    ForEach(VoiceKitAppearance.allCases, id: \.rawValue) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                Picker("文字大小", selection: $textScaleRawValue) {
                    ForEach(VoiceKitTextScale.allCases, id: \.rawValue) { scale in
                        Text(scale.title).tag(scale.rawValue)
                    }
                }
            } header: {
                Text("界面")
            } footer: {
                Text("默认使用 macOS 系统字体；较大和更大只调整 VoiceKit 的界面文字，不改变系统设置。")
            }

            Section("声音") {
                Toggle("开始录音提示音", isOn: startSoundEnabledBinding)
                if draft.general.sound.start {
                    HStack {
                        Picker("开始录音音效", selection: $draft.general.sound.startSound) {
                            ForEach(Self.systemSounds, id: \.0) { n, l in Text(l).tag(n) }
                        }
                        Button("试听") { NSSound(named: .init(draft.general.sound.startSound))?.play() }
                    }
                }
                Toggle("识别完成提示音", isOn: stopSoundEnabledBinding)
                if draft.general.sound.stop {
                    HStack {
                        Picker("识别完成音效", selection: $draft.general.sound.stopSound) {
                            ForEach(Self.systemSounds, id: \.0) { n, l in Text(l).tag(n) }
                        }
                        Button("试听") { NSSound(named: .init(draft.general.sound.stopSound))?.play() }
                    }
                }
            }

            Section {
                Button("恢复默认设置…", role: .destructive) { showResetConfirm = true }
            } footer: {
                Text("将所有设置恢复为 VoiceKit 出厂默认值。恢复后需点击右下角「保存」生效，直接关闭窗口可放弃。")
            }
        }
    }

    private var startSoundEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.general.sound.start },
            set: { draft.general.sound.startEnabled = $0 }
        )
    }

    private var stopSoundEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.general.sound.stop },
            set: { draft.general.sound.stopEnabled = $0 }
        )
    }

    // MARK: - 语音识别

    private var asrTab: some View {
        Group {
            Section {
                Picker("识别引擎", selection: $draft.asr.engine) {
                    Text("系统听写").tag("system")
                    Text("阿里云 Fun-ASR").tag("aliyun")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } header: {
                Text("识别引擎")
            } footer: {
                Text("macOS 内置语音识别，免费无需联网。阿里云高精度自动标点，需配置 API Key。")
            }

            Section {
                Picker("识别语言", selection: $draft.asr.system.language) {
                    Text("中文").tag("zh-Hans-CN")
                    Text("English").tag("en-US")
                    Text("日本語").tag("ja-JP")
                    Text("한국어").tag("ko-KR")
                    Text("Français").tag("fr-FR")
                    Text("Deutsch").tag("de-DE")
                    Text("Español").tag("es-ES")
                    Text("Português").tag("pt-BR")
                    Text("Русский").tag("ru-RU")
                    Text("Italiano").tag("it-IT")
                }
            } footer: {
                Text("选择你说什么语言，偶尔夹带外文单词也能识别")
            }

            // 阿里云专属配置
            if draft.asr.engine == "aliyun" {
                Section("标点与断句") {
                    Toggle("语义断句", isOn: $draft.asr.aliyun.semanticPunctuation)
                    if !draft.asr.aliyun.semanticPunctuation {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("停顿时长")
                                Slider(value: Binding(get: { Double(draft.asr.aliyun.maxSentenceSilence) },
                                                       set: { draft.asr.aliyun.maxSentenceSilence = Int($0) }),
                                       in: 200...6000, step: 100)
                                Text("\(draft.asr.aliyun.maxSentenceSilence)ms")
                                    .font(typography.callout).frame(width: 55, alignment: .trailing)
                            }
                            Text("说话停顿超过此时长则断句。值越小断句越频繁。")
                                .font(typography.callout).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("VAD 灵敏度")
                            Slider(value: $draft.asr.aliyun.speechNoiseThreshold, in: -1...1, step: 0.1)
                            Text(String(format: "%+.1f", draft.asr.aliyun.speechNoiseThreshold))
                                .font(typography.callout).frame(width: 40, alignment: .trailing)
                        }
                        Text("负值更敏感（更容易判定为语音），正值更保守（更容易判定为静音）。")
                            .font(typography.callout).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("静音自动停止", isOn: $draft.asr.aliyun.autoStopEnabled)
                    if draft.asr.aliyun.autoStopEnabled {
                        HStack {
                            Text("静音阈值")
                            Slider(value: $draft.asr.aliyun.autoStopThreshold, in: 0.005...0.1, step: 0.005)
                            Text(String(format: "%.3f", draft.asr.aliyun.autoStopThreshold))
                                .font(typography.callout).frame(width: 45, alignment: .trailing)
                        }
                        HStack {
                            Text("超时时间")
                            Slider(value: $draft.asr.aliyun.autoStopTimeout, in: 1...10, step: 0.5)
                            Text(String(format: "%.1fs", draft.asr.aliyun.autoStopTimeout))
                                .font(typography.callout).frame(width: 40, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("开启后，说话停顿超过设定时间会自动结束听写并粘贴，不用再按一次热键")
                }

                Section("API 配置") {
                    HStack(spacing: 4) {
                        if showAPIKey {
                            TextField("API Key", text: $draft.asr.aliyun.apiKey, prompt: Text("sk-..."))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $draft.asr.aliyun.apiKey, prompt: Text("sk-..."))
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showAPIKey.toggle() }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAPIKey ? "隐藏 API Key" : "显示 API Key")
                    }
                    TextField("Workspace ID", text: $draft.asr.aliyun.workspaceId, prompt: Text("ws-..."))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        TextField("区域", text: $draft.asr.aliyun.region, prompt: Text("cn-beijing"))
                            .textFieldStyle(.roundedBorder)
                        TextField("模型", text: $draft.asr.aliyun.model, prompt: Text("fun-asr-realtime"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    // MARK: - AI 服务总览

    private var aiServiceOverviewTab: some View {
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
                    Toggle("启用 AI 润色", isOn: $draft.llm.enabled)
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

    private func overviewStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(typography.callout.bold())
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(typography.body.bold())
                Text(detail).font(typography.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 模型管理

    private var modelTab: some View {
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
    private func modelRow(_ model: LLMModelDef) -> some View {
        let result = modelTestResults[model.id]
        return HStack(alignment: .top, spacing: 10) {
            Button {
                draft.llm.selectedModelID = model.id
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.id == draft.llm.selectedModelID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.id == draft.llm.selectedModelID ? Color.accentColor : VoiceKitSemanticColor.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name.isEmpty ? "未命名模型" : model.name)
                            .font(typography.body)
                            .foregroundStyle(.primary)
                        Text("\(Self.engineDisplayName(model.engine)) · \(model.model) · Token \(model.totalTokens) · 使用 \(model.usageCount) 次")
                            .font(typography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // 测试失败的完整错误独占一行换行展示，不与右侧按钮争抢宽度
                        if let result, !result.success {
                            Text(result.error ?? "未知错误")
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
            .accessibilityLabel("选择模型 \(model.name)")

            Spacer(minLength: 4)

            if let result {
                if result.success {
                    Text("\(result.latencyMs ?? 0)ms")
                        .font(typography.callout)
                        .foregroundStyle(VoiceKitSemanticColor.success)
                } else {
                    Text("失败")
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
            .accessibilityLabel("删除模型 \(model.name)")
        }
        .padding(.vertical, 2)
    }

    private static func engineDisplayName(_ engine: String) -> String {
#if APP_STORE
        engine == "openai" ? "云端 API" : "Ollama"
#else
        engine == "openai" ? "OpenAI" : "Ollama"
#endif
    }

    private static func makeNewModel() -> LLMModelDef {
#if APP_STORE
        LLMModelDef(name: "", engine: "openai", baseUrl: "", apiKey: "", model: "")
#else
        LLMModelDef(name: "", engine: "openai", baseUrl: "https://api.openai.com/v1", apiKey: "", model: "gpt-4o-mini")
#endif
    }

    private func runModelBatchTest() {
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
                    let stream = engine.polish("ping", system: "回复 OK", userTemplate: "回复 OK")
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

    private var thinkingBinding: Binding<Bool> {
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

    private var promptTab: some View {
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
    private func promptRow(id: String, name: String, subtitle: String, deletable: Bool, preset: LLMPromptPreset? = nil) -> some View {
        HStack(spacing: 10) {
            Button {
                draft.llm.selectedPromptID = id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: draft.llm.selectedPromptID == id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(draft.llm.selectedPromptID == id ? Color.accentColor : VoiceKitSemanticColor.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name)
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
            .accessibilityLabel("选择提示词 \(name)")

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
                .accessibilityLabel("删除提示词 \(name)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 提示词预设操作

    /// 以当前选中的提示词（含系统默认）为模板复制一份新的
    private func addPromptPreset() {
        let base = draft.llm.activePrompt
        let new = LLMPromptPreset(
            name: "提示词 \(draft.llm.prompts.count + 1)",
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

    private var permissionTab: some View {
        Group {
            Section {
                permissionRow(
                    icon: "mic.fill",
                    name: "麦克风",
                    why: "听到你的声音，才能转成文字",
                    ifDenied: "不授权：无法使用语音输入",
                    status: micStatus,
                    action: requestMicPermission
                )
            }

            Section {
                permissionRow(
                    icon: "text.bubble.fill",
                    name: "语音识别",
                    why: "把你说的话实时转写成文字",
                    ifDenied: "不授权：无法使用语音输入",
                    status: speechStatus,
                    action: requestSpeechPermission
                )
            }

            // 合成键盘事件（App Store 版和官网版的剪贴板回退路径都需要）
            Section {
                permissionRow(
                    icon: "keyboard.fill",
                    name: "自动写回（键盘事件）",
                    why: "允许 VoiceKit 在识别完成后尝试发送一次 ⌘V",
                    ifDenied: "不授权：文字仍会保留在剪贴板，请手动按 ⌘V",
                    status: postEventStatus,
                    action: requestPostEventPermission
                )
            }

            // 辅助功能（仅官网版）
#if !APP_STORE
            Section {
                permissionRow(
                    icon: "rectangle.and.hand.point.up.left.fill",
                    name: "辅助功能（直接写入）",
                    why: "允许 VoiceKit 直接访问目标输入框写入文字",
                    ifDenied: "不授权：会回退到剪贴板，请手动按 ⌘V",
                    status: accessibilityStatus,
                    action: requestAccessibilityPermission
                )
            }

            if restartState == .recommended {
                Section {
                    restartRow
                }
            }
#endif

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("权限状态会在返回 VoiceKit 时刷新", systemImage: "arrow.triangle.2.circlepath")
                        .font(typography.callout).foregroundStyle(.secondary)
                    Text(permissionReloadHint)
                        .font(typography.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

#if !APP_STORE
                    Label("多个 VoiceKit 副本", systemImage: "doc.on.doc")
                        .font(typography.callout).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("如果你安装过多个版本的 VoiceKit（比如从官网下载的 DMG 和从 App Store 下载的版本），每个版本需要单独授权。它们是 macOS 眼中的「不同 App」。")
                        .font(typography.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
#endif
                }
                .padding(.vertical, 4)
            } header: {
                Text("说明")
            }
        }
        // 从系统设置返回 App 时刷新权限状态，保证授权结果立即反映到界面
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshID = UUID()
        }
    }

    // MARK: - 数据隐私

    private var privacyTab: some View {
        Group {
            Section("你决定数据去哪里") {
                privacyRow(icon: "house.fill", color: .green,
                           title: "系统听写",
                           detail: "使用 macOS 内置语音识别，语音由系统处理。")
                privacyRow(icon: "cloud.fill", color: .blue,
                           title: "阿里云 Fun-ASR",
                           detail: "语音直接发送到你自己配置的阿里云服务实例。")
                privacyRow(icon: "cpu.fill", color: .orange,
                           title: "AI 润色",
                           detail: "识别文字直接发送到你配置的云端 API 或本地模型。使用本地模型时，文字不会离开这台 Mac。")
            }

            Section {
                Text("除了你自己配置的语音识别和 AI 服务，VoiceKit 不调用其他 API 服务。没有后台服务器，不收集语音或文字，不统计使用情况，也不追踪用户行为。")
                    .font(typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("VoiceKit 不提供中转服务", systemImage: "hand.raised.fill")
            } footer: {
                Text("API Key、模型地址和提示词只保存在本机配置中，并按你的设置使用。")
            }
        }
    }

    private func privacyRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(typography.body.bold())
                Text(detail)
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var micStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var speechStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var postEventStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        if PasteService.shared.canPostEvents { return .granted }
        return postEventRequestAttempted ? .denied : .notDetermined
    }

    private var permissionReloadHint: String {
#if APP_STORE
        return "App Store 版不使用辅助功能直接写入；麦克风、语音识别和键盘事件权限通常会立即刷新。"
#else
        if restartState == .recommended {
            return "辅助功能刚刚授权，请使用上方的重启按钮；麦克风和语音识别权限通常不需要重启。"
        }
        return "只有辅助功能在刚授权后可能需要重启；麦克风和语音识别权限通常不需要重启。"
#endif
    }

    /// 未决定时触发系统授权弹窗（App Review 5.1.1(iv)：按钮用「继续」而非「去授权」）；
    /// 已被拒绝时系统弹窗不会再出现，改为打开对应系统设置页。
    /// 必须 Task.detached：权限回调在后台线程（TCC XPC 回复队列）触发，
    /// 闭包若从 View 继承 MainActor 隔离，会触发 swift_task_checkIsolatedSwift
    /// 断言崩溃（EXC_BAD_INSTRUCTION，Release 同样崩）。
    private func requestMicPermission() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            PasteService.shared.openMicrophoneSettings()
            return
        }
        Task.detached {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            await MainActor.run { permissionRefreshID = UUID() }
        }
    }

    private func requestSpeechPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            PasteService.shared.openSpeechSettings()
            return
        }
        Task.detached {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            await MainActor.run { permissionRefreshID = UUID() }
        }
    }

    private func requestPostEventPermission() {
        guard !PasteService.shared.canPostEvents else { return }
        guard !postEventRequestAttempted else {
            PasteService.shared.openPostEventSettings()
            return
        }
        postEventRequestAttempted = true
        _ = PasteService.shared.requestPostEventAccess()
        permissionRefreshID = UUID()
    }

#if !APP_STORE
    private var accessibilityStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        if PasteService.shared.isTrusted { return .granted }
        let elem = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(elem, kAXFocusedUIElementAttribute as CFString, &focused)
        if result == .success { return .granted }
        return .notDetermined
    }

    /// 辅助功能没有异步授权 API：AXIsProcessTrustedWithOptions(prompt: true)
    /// 会弹出系统授权提示，并把 App 自动加入辅助功能列表（默认未勾选），
    /// 用户勾选后生效。授权结果不回调，靠 didBecomeActiveNotification 刷新状态。
    private func requestAccessibilityPermission() {
        guard !PasteService.shared.isTrusted else { return }
        restartRequested = true
        // kAXTrustedCheckOptionPrompt 是可变全局变量，Swift 6 并发检查不允许直接引用；
        // 该 key 字符串是稳定 API，直接使用字面量。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
#endif

    private var restartState: VoiceKitPermissionReloadState {
#if APP_STORE
        return .hidden
#else
        return VoiceKitPermissionReloadState.make(
            distribution: .direct,
            permission: accessibilityStatus,
            requested: restartRequested
        )
#endif
    }

    private func permissionRow(icon: String, name: String, why: String, ifDenied: String, status: VoiceKitPermissionState, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(status == .granted ? VoiceKitSemanticColor.success : VoiceKitSemanticColor.secondaryText)
                    .frame(width: 24)
                Text(name).font(typography.body).bold()
                Spacer()
                statusBadge(status)
                if status != .granted {
                    // App Review 5.1.1(iv)：授权弹窗前的按钮用「继续」这类中性文案；
                    // 已被拒绝时按钮的作用是跳转系统设置，如实标注。
                    Button(status == .notDetermined ? "继续" : "打开系统设置") { action() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(why)
                .font(typography.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status != .granted {
                Text(ifDenied)
                    .font(typography.callout).foregroundStyle(VoiceKitSemanticColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ status: VoiceKitPermissionState) -> some View {
        switch status {
        case .granted:
            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(VoiceKitSemanticColor.success).font(typography.callout)
        case .denied:
            Label("已拒绝", systemImage: "xmark.circle.fill").foregroundStyle(VoiceKitSemanticColor.failure).font(typography.callout)
        case .notDetermined:
            Label("未授权", systemImage: "questionmark.circle").foregroundStyle(VoiceKitSemanticColor.warning).font(typography.callout)
        }
    }

#if !APP_STORE
    private var restartRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("辅助功能已授权")
                    .font(typography.sectionTitle)
                Text("重启 VoiceKit，让刚授权的直接写入能力完整生效。")
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("现在重启 VoiceKit") {
                        restartApplication()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("稍后处理") {
                        restartRequested = false
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
#endif

    private func closeSettings() {
        if hasChanges {
            showDiscardAlert = true
        } else {
            onDone()
        }
    }

    /// 当前 draft 与打开时的原始配置是否有差异
    private var hasChanges: Bool {
        draft != originalConfig
    }

    // MARK: - 保存

    private func save() {
        // 阿里云：检查必填
        if draft.asr.engine == "aliyun" {
            if draft.asr.aliyun.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "阿里云 Fun-ASR 的 API Key 不能为空"
                showValidationAlert = true; return
            }
            if draft.asr.aliyun.workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "阿里云 Fun-ASR 的 Workspace ID 不能为空"
                showValidationAlert = true; return
            }
        }
        // LLM：检查选中模型是否存在且必填字段完整
        if draft.llm.enabled {
            guard let model = draft.llm.selectedModel else {
                validationMessage = "请先添加并选择一个 LLM 模型"
                showValidationAlert = true; return
            }
            if model.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "模型「\(model.name)」的 Base URL 不能为空"
                showValidationAlert = true; return
            }
            if model.engine == "openai" && model.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "模型「\(model.name)」的 API Key 不能为空"
                showValidationAlert = true; return
            }
            if model.model.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "模型「\(model.name)」的模型名不能为空"
                showValidationAlert = true; return
            }
        }
        if let loginItemErr = ConfigStore.shared.update(draft) {
            validationMessage = "登录项设置失败：\(loginItemErr)"
            showValidationAlert = true
            return
        }
        HotkeyManager.shared.register(hotkeyString: draft.general.hotkey)
        originalConfig = draft
        DispatchQueue.main.async {
            self.onDone()
        }
    }

    // MARK: - 关于

    private var aboutTab: some View {
        Group {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VoiceKit").font(typography.title).bold()
                        Text("macOS 语音输入助手 — 全局热键，说话即输入")
                            .font(typography.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(aboutVersionString)
                                .font(typography.callout).foregroundStyle(.secondary)
                            Text("·")
                                .font(typography.callout).foregroundStyle(.secondary)
#if APP_STORE
                            Text("App Store")
                                .font(typography.callout).foregroundStyle(.tint)
#else
                            Text("官网版")
                                .font(typography.callout).foregroundStyle(.secondary)
#endif
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 开源声明
            Section {
                Text("VoiceKit 是完全开源的软件，代码托管在 GitHub，任何人都可以查看、审计和参与改进。没有付费墙，没有隐藏费用，也不需要注册任何账号。")
                    .font(typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("开源免费 · 无需注册", systemImage: "lock.open")
            }

            // 联系与更新
            Section {
                contactRow(icon: "envelope.fill", value: ContactInfo.email)
                contactRow(icon: "safari.fill", value: ContactInfo.website)
                contactRow(icon: "chevron.left.forwardslash.chevron.right", value: ContactInfo.github)
            } header: {
                Label("联系与更新", systemImage: "envelope")
            } footer: {
                Text("链接仅作为信息展示；使用右侧复制按钮后，可在浏览器或邮件客户端中使用。\n\nCopyright © 2026 VoiceKit. MIT License.")
            }
        }
    }

    /// 从 Info.plist 读取版本号
    private var aboutVersionString: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "版本 \(ver) (build \(build))"
    }

    private func contactRow(icon: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(typography.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(typography.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制")
            .accessibilityLabel("复制 \(value)")
        }
    }
}

// MARK: - 提示词预览 Sheet

private struct PromptPreviewSheet: View {
    let systemPrompt: String
    let userTemplate: String
    let language: String
    let engine: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        let tmpl = PromptTemplate(system: systemPrompt, user: userTemplate)
        let (sys, usr) = tmpl.render(input: "今天天气真好我们出去走走吧", language: language, engine: engine)

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

private struct LLMTestSheet: View {
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
            Text(title).font(typography.callout).foregroundStyle(.secondary)
            content()
        }
    }

    private func runTest() {
        isRunning = true
        errorMsg = nil
        resultText = ""
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard let model = llmConfig.selectedModel else {
            errorMsg = "未选择模型"
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
                    resultText = acc.isEmpty ? "(返回为空)" : acc
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMsg = "请求失败：\(error.localizedDescription)"
                    isRunning = false
                }
            }
        }
    }
}

// MARK: - 模型编辑器 Sheet（新增 / 编辑）

private struct ModelEditorSheet: View {
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
            Text(model.name.isEmpty ? "添加模型" : "编辑模型").font(typography.sectionTitle)

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

            Text("累计 Token：\(model.totalTokens)  ·  使用次数：\(model.usageCount)")
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
            Text(title).font(typography.callout).foregroundStyle(.secondary)
            content()
        }
    }
}


// MARK: - 提示词编辑器 Sheet（编辑默认/用户预设）

private struct PromptEditorSheet: View {
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
            Text(isSystemDefault ? "编辑默认提示词" : "编辑提示词")
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

            Text("保留 {{input}} 占位符，运行时会替换为原始语音文本。")
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
            Text(title).font(typography.callout).foregroundStyle(.secondary)
            content()
        }
    }
}
