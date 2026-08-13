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
    /// 窗口控制器桥：同步未保存变更状态，接收红叉关闭的确认请求
    var bridge: SettingsWindowBridge? = nil
    var onDone: () -> Void = {}
    var onTabChange: (Int) -> Void = { _ in }

    @State private var draft: AppConfig = ConfigStore.shared.config
    /// 打开设置时的原始配置，用于判断是否有未保存变更
    @State private var originalConfig: AppConfig = ConfigStore.shared.config
    @AppStorage("voicekit.settings.selectedPane") private var selectedPaneRawValue = SettingsPane.general.rawValue
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @AppStorage("voicekit.ui.appearance") private var appearanceRawValue = VoiceKitAppearance.system.rawValue
    /// 界面语言偏好：空字符串 = 跟随系统；否则为 lproj 目录名（zh-Hans/en/…）。
    /// 与外观/文字大小一样是即时生效的 UI 偏好，但语言包在下次启动才加载，
    /// 所以改动后提示重启（NSLocalizedString 由系统按 AppleLanguages 解析）。
    @AppStorage("voicekit.ui.language") private var languageRawValue = ""
    /// 本次启动时的语言偏好，用于判断改动后是否需要提示重启
    private let launchedLanguageRawValue = UserDefaults.standard.string(forKey: "voicekit.ui.language") ?? ""
    @State private var languageNeedsRestart = false
    @State private var selectedPane = SettingsPane.general
    @State private var showAPIKey = false
    @State private var permissionRefreshID = UUID()
    /// 本地数据各文件的大小（进入隐私分页时刷新）。
    @State private var localDataSizes: [String: UInt64] = [:]
    @State private var postEventRequestAttempted = false
    @State private var postEventRestartDismissed = false
    @State private var restartRequested = false

    // 保存校验
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    // 启用 AI 润色前的模型校验
    @State private var showLLMEnableGuardAlert = false
    @State private var llmEnableGuardMessage = ""

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

    // ASR 连接测试
    @State private var connTestRunning: String?
    @State private var connTestResults: [String: ASRConnTestResult] = [:]

    @State private var showDiscardAlert = false

    var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
            detailColumn
                // 内容区作为白色圆角卡片浮在窗口底色上（macOS 26 Finder 版式）
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 580)
        .voiceKitTextScale(selectedTextScale)
        .onAppear {
            selectedPane = SettingsPane.restored(from: selectedPaneRawValue)
            onTabChange(selectedPane.index)
            bridge?.hasChanges = hasChanges
        }
        .onChange(of: selectedPane) { _, newPane in
            selectedPaneRawValue = newPane.rawValue
            onTabChange(newPane.index)
        }
        // 未保存变更状态同步给窗口控制器（红叉关闭确认用）
        .onChange(of: hasChanges) { _, newValue in
            bridge?.hasChanges = newValue
        }
        // 红叉/Cmd+W 被控制器拦截后，这里弹出与「关闭」按钮一致的确认框
        .onChange(of: bridge?.discardConfirmationRequested ?? false) { _, requested in
            guard requested else { return }
            bridge?.discardConfirmationRequested = false
            showDiscardAlert = true
        }
        // 设置页打开期间，状态栏菜单等外部路径改了配置：
        // 没有本地未保存变更时刷新快照，避免保存时把外部修改覆盖回去。
        .onReceive(NotificationCenter.default.publisher(for: ConfigStore.didChange)) { _ in
            guard !hasChanges else { return }
            let latest = ConfigStore.shared.config
            draft = latest
            originalConfig = latest
        }
        .alert("保存失败", isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
        .alert("暂时无法启用 AI 润色", isPresented: $showLLMEnableGuardAlert) {
            Button("好", role: .cancel) {}
            Button("前往模型管理") { selectedPane = .models }
        } message: {
            Text(llmEnableGuardMessage)
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
            Text(VoiceKitLocalization.format("确定要删除「%@」吗？此操作不可撤销。", modelToDelete?.name ?? ""))
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
            Text(VoiceKitLocalization.format("确定要删除「%@」吗？删除后将切回系统默认提示词。", promptToDelete?.name ?? ""))
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

    // MARK: - 布局

    /// 侧边栏：SDK 原生 .sidebar 样式（选中态/分隔样式都在），
    /// 但刻意不用 NavigationSplitView——它在 macOS 26 的手工 NSWindow 里
    /// 会裁切侧栏首行，且折叠按钮要靠遍历 NSToolbar 的 hack 移除。
    /// 侧栏做成悬浮圆角面板（系统 .sidebar 材质），内容区为白色圆角卡片，
    /// 即 macOS 26 Finder 的版式；结构稳定，版式完全可控。
    private var sidebarColumn: some View {
        List(SettingsPane.allCases, selection: $selectedPane) { pane in
            Label(pane.title, systemImage: pane.systemImage)
                .tag(pane)
                .padding(.leading, pane.isSubpane ? 16 : 0)
        }
        .listStyle(.sidebar)
        .font(typography.body)
        // 隐藏 List 自带背景，垫系统 .sidebar 材质（withinWindow 混合：
        // 与窗口白底混合，颜色与 Finder/系统设置侧栏完全一致，
        // 不透桌面、不受壁纸影响；跟随窗口激活态变浅灰是系统标准行为）
        .scrollContentBackground(.hidden)
        .background(SidebarMaterialBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        // 极轻投影制造「浮在窗口上」的层次
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 0))
        .frame(width: 200 * selectedTextScale.multiplier)
    }

    private var detailColumn: some View {
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
                // 切换页面时重建 Form：否则滚动位置/内部状态跨页残留，版式看起来错乱
                .id(selectedPane)
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
        // 圆角内容卡片：白色底 + 细描边（深色模式自动取深色语义色）
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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

    // MARK: - 界面语言

    /// 可选界面语言：code 为 lproj 目录名（即 AppleLanguages 取值），
    /// name 用各语言自称（这部分不需要本地化）。
    private static let availableLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("pt-BR", "Português (Brasil)"),
    ]

    /// 写入 AppleLanguages 覆盖系统语言；空值恢复跟随系统。
    /// 语言包在下次启动时由系统解析，故改动后提示重启。
    private func applyLanguagePreference(_ raw: String) {
        if raw.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([raw], forKey: "AppleLanguages")
        }
        languageNeedsRestart = (raw != launchedLanguageRawValue)
    }

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
                Picker("语言", selection: $languageRawValue) {
                    Text("跟随系统").tag("")
                    ForEach(Self.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .onChange(of: languageRawValue) { _, newValue in
                    applyLanguagePreference(newValue)
                }
                if languageNeedsRestart {
                    HStack(spacing: 8) {
                        Text("界面语言将在重启 VoiceKit 后生效。")
                            .font(typography.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("现在重启 VoiceKit") { restartApplication() }
                    }
                }
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

    /// 启用 AI 润色前校验：无可用模型或模型信息不完整时阻止开启并给出引导。
    private var llmEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.llm.enabled },
            set: { v in
                guard v else {
                    draft.llm.enabled = false
                    return
                }
                guard let model = draft.llm.selectedModel else {
                    llmEnableGuardMessage = VoiceKitLocalization.string("还没有可用的模型。请先到「模型管理」添加模型，再启用 AI 润色。")
                    showLLMEnableGuardAlert = true
                    return
                }
                if model.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty ||
                   model.model.trimmingCharacters(in: .whitespaces).isEmpty {
                    llmEnableGuardMessage = VoiceKitLocalization.format("当前选中的模型「%@」信息不完整，请到「模型管理」中补全 Base URL 和模型名。", model.name)
                    showLLMEnableGuardAlert = true
                    return
                }
                draft.llm.enabled = true
            }
        )
    }

    // MARK: - 语音识别

    private var asrTab: some View {
        Group {
            Section {
                engineRow("system",
                          title: VoiceKitLocalization.string("系统听写"),
                          desc: VoiceKitLocalization.string("macOS 内置语音识别，免费、无需配置即可使用"))
                engineRow("aliyun",
                          title: VoiceKitLocalization.string("阿里云 Fun-ASR"),
                          desc: VoiceKitLocalization.string("高精度、自动标点，支持长连续口述；需阿里云百炼 API Key"))
                engineRow("xunfei",
                          title: VoiceKitLocalization.string("讯飞听写"),
                          desc: VoiceKitLocalization.string("中文高精度、支持动态修正；仅支持中/英文，单次会话约 60 秒上限（到时自动写入已识别内容）；需讯飞开放平台凭据"))
                engineRow("deepgram",
                          title: "Deepgram",
                          desc: VoiceKitLocalization.string("多语言高精度实时识别，支持长连续口述；需 Deepgram API Key"))
            } header: {
                Text("识别引擎")
            } footer: {
                Text("云端引擎需自备 API 凭据；未配置的云端引擎会自动回退到系统听写。")
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
                            Text("超时时间")
                            Slider(value: $draft.asr.aliyun.autoStopTimeout, in: 1...10, step: 0.5)
                            Text(String(format: "%.1fs", draft.asr.aliyun.autoStopTimeout))
                                .font(typography.callout).frame(width: 40, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("开启后，说话停顿超过设定时间会自动结束听写并粘贴，不用再按一次热键。判定静音的音量高低由程序按环境噪音自动适应，无需手动设置。")
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
                        .accessibilityLabel(showAPIKey
                                            ? VoiceKitLocalization.string("隐藏 API Key")
                                            : VoiceKitLocalization.string("显示 API Key"))
                    }
                    TextField("Workspace ID", text: $draft.asr.aliyun.workspaceId, prompt: Text("ws-..."))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        TextField("区域", text: $draft.asr.aliyun.region, prompt: Text("cn-beijing"))
                            .textFieldStyle(.roundedBorder)
                        TextField("模型", text: $draft.asr.aliyun.model, prompt: Text("fun-asr-realtime"))
                            .textFieldStyle(.roundedBorder)
                    }
                    connTestRow(engineID: "aliyun",
                                enabled: !draft.asr.aliyun.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                                    && !draft.asr.aliyun.workspaceId.trimmingCharacters(in: .whitespaces).isEmpty) {
                        await ASRConnectionTester.testAliyun(draft.asr.aliyun)
                    }
                }
            }

            // 讯飞专属配置
            if draft.asr.engine == "xunfei" {
                Section {
                    Toggle("动态修正", isOn: $draft.asr.xunfei.dynamicCorrection)
                } footer: {
                    Text("开启后讯飞会自动修正已返回的中间结果，识别更准，仅中文支持。")
                }

                Section {
                    Toggle("静音自动停止", isOn: $draft.asr.xunfei.autoStopEnabled)
                    if draft.asr.xunfei.autoStopEnabled {
                        HStack {
                            Text("超时时间")
                            Slider(value: $draft.asr.xunfei.autoStopTimeout, in: 1...10, step: 0.5)
                            Text(String(format: "%.1fs", draft.asr.xunfei.autoStopTimeout))
                                .font(typography.callout).frame(width: 40, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("开启后，说话停顿超过设定时间会自动结束听写并粘贴，不用再按一次热键。判定静音的音量高低由程序按环境噪音自动适应，无需手动设置。")
                }

                Section {
                    TextField("App ID", text: $draft.asr.xunfei.appId, prompt: Text("12345678"))
                        .textFieldStyle(.roundedBorder)
                    secretField("API Key", text: $draft.asr.xunfei.apiKey)
                    secretField("API Secret", text: $draft.asr.xunfei.apiSecret)
                    connTestRow(engineID: "xunfei",
                                enabled: !draft.asr.xunfei.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                                    && !draft.asr.xunfei.apiSecret.trimmingCharacters(in: .whitespaces).isEmpty) {
                        await ASRConnectionTester.testXunfei(draft.asr.xunfei)
                    }
                } header: {
                    Text("API 配置")
                } footer: {
                    Text("在讯飞开放平台创建应用后，于「语音听写（流式版）」服务下查看三要素。")
                }
            }

            // Deepgram 专属配置
            if draft.asr.engine == "deepgram" {
                Section {
                    Toggle("静音自动停止", isOn: $draft.asr.deepgram.autoStopEnabled)
                    if draft.asr.deepgram.autoStopEnabled {
                        HStack {
                            Text("超时时间")
                            Slider(value: $draft.asr.deepgram.autoStopTimeout, in: 1...10, step: 0.5)
                            Text(String(format: "%.1fs", draft.asr.deepgram.autoStopTimeout))
                                .font(typography.callout).frame(width: 40, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("开启后，说话停顿超过设定时间会自动结束听写并粘贴，不用再按一次热键。判定静音的音量高低由程序按环境噪音自动适应，无需手动设置。")
                }

                Section {
                    secretField("API Key", text: $draft.asr.deepgram.apiKey)
                    TextField("模型", text: $draft.asr.deepgram.model, prompt: Text("nova-3"))
                        .textFieldStyle(.roundedBorder)
                    connTestRow(engineID: "deepgram",
                                enabled: !draft.asr.deepgram.apiKey.trimmingCharacters(in: .whitespaces).isEmpty) {
                        await ASRConnectionTester.testDeepgram(draft.asr.deepgram)
                    }
                } header: {
                    Text("API 配置")
                } footer: {
                    Text("在 console.deepgram.com 创建 API Key。")
                }
            }
        }
    }

    /// 引擎选择行：标题 + 一句介绍 + 选中标记。
    private func engineRow(_ engineID: String, title: String, desc: String) -> some View {
        let selected = draft.asr.engine == engineID
        return Button {
            draft.asr.engine = engineID
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(typography.body)
                    Text(desc)
                        .font(typography.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 连接测试行：按钮 + 结果展示（失败时透传服务商原始信息）。
    private func connTestRow(engineID: String, enabled: Bool,
                             action: @escaping () async -> ASRConnTestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                connTestRunning = engineID
                connTestResults[engineID] = nil
                Task {
                    let result = await action()
                    connTestRunning = nil
                    connTestResults[engineID] = result
                }
            } label: {
                if connTestRunning == engineID {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在测试…")
                    }
                } else {
                    Text("测试连接")
                }
            }
            .disabled(!enabled || connTestRunning == engineID)
            if let result = connTestResults[engineID] {
                switch result {
                case .ok:
                    Label("连接成功", systemImage: "checkmark.circle.fill")
                        .font(typography.callout)
                        .foregroundStyle(VoiceKitSemanticColor.success)
                case .failed(let detail):
                    Text(VoiceKitLocalization.format("连接失败：%@", detail))
                        .font(typography.callout)
                        .foregroundStyle(VoiceKitSemanticColor.failure)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 带明/密文切换的密钥输入框。
    private func secretField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            if showAPIKey {
                TextField(label, text: text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(label, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            Button(action: { showAPIKey.toggle() }) {
                Image(systemName: showAPIKey ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAPIKey
                                ? VoiceKitLocalization.string("隐藏 API Key")
                                : VoiceKitLocalization.string("显示 API Key"))
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

    private func overviewStep(_ number: String, title: String, detail: String) -> some View {
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

    private static func engineDisplayName(_ engine: String) -> String {
#if APP_STORE
        engine == "openai"
            ? VoiceKitLocalization.string("云端 API")
            : VoiceKitLocalization.string("Ollama")
#else
        engine == "openai" ? "OpenAI" : VoiceKitLocalization.string("Ollama")
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
    private func addPromptPreset() {
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

            // 合成键盘事件：仅 App Store 版显示（它是沙盒下唯一的自动写回授权）。
            // 官网版不显示此行——辅助功能与键盘事件在系统设置中是同一面板，
            // 不愿授 AX 的用户也不会单独授键盘事件；AX 未授权时的体验与提示
            // 由「辅助功能」行的 ifDenied 文案（回退剪贴板手动 ⌘V）承载。
#if APP_STORE
            Section {
                postEventPermissionRow
            } footer: {
                Text("此权限仅用于把识别结果写入你当前的输入框（由系统代为发送一次 ⌘V）。VoiceKit 不监听你的键盘输入，也不读取屏幕内容，可放心授权。")
            }
#else
            // 辅助功能（仅官网版）
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
#endif

            // 重启提示（两版通用：辅助功能/键盘事件授权后，TCC 进程级缓存需重启刷新）
            if case .recommended = restartState {
                Section {
                    restartRow
                }
            }

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
                privacyRow(icon: "cloud.fill", color: .blue,
                           title: "讯飞听写",
                           detail: "语音直接发送到你自己配置的讯飞开放平台账号。")
                privacyRow(icon: "cloud.fill", color: .blue,
                           title: "Deepgram",
                           detail: "语音直接发送到你自己配置的 Deepgram 账号。")
                privacyRow(icon: "cpu.fill", color: .orange,
                           title: "AI 润色",
                           detail: "识别文字直接发送到你配置的云端 API 或本地模型。使用本地模型时，文字不会离开这台 Mac。")
            }

            Section {
                Text("除了你自己配置的语音识别和 AI 服务，VoiceKit 不调用其他 API 服务。没有后台服务器，不会把语音、文字或任何使用数据上传到别处，也不追踪用户行为。")
                    .font(typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("VoiceKit 不提供中转服务", systemImage: "hand.raised.fill")
            } footer: {
                Text("API Key、模型地址和提示词只保存在本机配置中，并按你的设置使用。")
            }

            Section {
                localDataRow(title: "配置", file: "config.json",
                             detail: "偏好设置与 API 密钥（明文保存）",
                             url: Self.supportFileURL("config.json"))
                localDataRow(title: "历史记录", file: "history.json",
                             detail: "最近若干条识别原文与润色结果",
                             url: Self.supportFileURL("history.json"), clearable: true)
                localDataRow(title: "运行日志", file: "voicekit.log",
                             detail: "含转录原文，仅用于排查问题，超过 2MB 自动覆盖较早内容",
                             url: Log.currentFileURL, clearable: true,
                             clear: { Log.clear(); refreshLocalDataSizes() })

                Toggle(isOn: Binding(
                    get: { draft.general.usageStatsEnabled },
                    set: { draft.general.usageStatsEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VoiceKitLocalization.string("记录使用统计"))
                            .font(typography.body)
                        Text(VoiceKitLocalization.string("stats.jsonl —— 仅记录时长、字数、引擎等元数据，不含任何文字内容"))
                            .font(typography.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text(VoiceKitLocalization.string("统计文件"))
                        .font(typography.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.formatBytes(localDataSizes["stats"] ?? 0))
                        .font(typography.callout).foregroundStyle(.secondary)
                    Button(VoiceKitLocalization.string("导出…")) { exportUsageStats() }
                        .controlSize(.small)
                    Button(VoiceKitLocalization.string("清空")) {
                        UsageStatsStore.shared.clear()
                        refreshLocalDataSizes()
                    }
                    .controlSize(.small)
                }
            } header: {
                Label("本地数据", systemImage: "internaldrive")
            } footer: {
                Text("以上文件只存在于这台 Mac 上。VoiceKit 没有服务器，不会上传其中任何内容。")
            }
        }
        .task { refreshLocalDataSizes() }
    }

    // MARK: - 本地数据

    private static func supportFileURL(_ name: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoiceMate", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "—" }
        let units = ["B", "KB", "MB"]
        var value = Double(bytes), idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return String(format: idx == 0 ? "%.0f %@" : "%.1f %@", value, units[idx])
    }

    private func refreshLocalDataSizes() {
        func size(_ url: URL?) -> UInt64 {
            guard let url,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
            return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        }
        localDataSizes = [
            "config.json": size(Self.supportFileURL("config.json")),
            "history.json": size(Self.supportFileURL("history.json")),
            "voicekit.log": size(Log.currentFileURL),
            "stats": UsageStatsStore.shared.fileSize
        ]
    }

    private func exportUsageStats() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voicekit-usage.jsonl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? UsageStatsStore.shared.export(to: dest)
    }

    @ViewBuilder
    private func localDataRow(title: String, file: String, detail: String,
                              url: URL?, clearable: Bool = false,
                              clear: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceKitLocalization.string(title)).font(typography.body)
                Text(VoiceKitLocalization.string(detail))
                    .font(typography.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Self.formatBytes(localDataSizes[file] ?? 0))
                .font(typography.callout).foregroundStyle(.secondary)
            if let url {
                Button(VoiceKitLocalization.string("显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
            if clearable {
                Button(VoiceKitLocalization.string("清空")) {
                    if let clear { clear() } else if let url {
                        try? FileManager.default.removeItem(at: url)
                        refreshLocalDataSizes()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func privacyRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceKitLocalization.string(title)).font(typography.body.bold())
                Text(VoiceKitLocalization.string(detail))
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

#if APP_STORE
    private var postEventStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        if PasteService.shared.canPostEvents { return .granted }
        return postEventRequestAttempted ? .denied : .notDetermined
    }

    /// 键盘事件授权行（仅 App Store 版；官网版不展示，见 permissionTab 注释）
    private var postEventPermissionRow: some View {
        permissionRow(
            icon: "keyboard.fill",
            name: "自动写回（键盘事件）",
            why: "允许 VoiceKit 在识别完成后尝试发送一次 ⌘V",
            ifDenied: "不授权：文字仍会保留在剪贴板，请手动按 ⌘V",
            status: postEventStatus,
            action: requestPostEventPermission
        )
    }
#endif

    private var distribution: VoiceKitDistribution {
#if APP_STORE
        .appStore
#else
        .direct
#endif
    }

    private var permissionReloadHint: String {
#if APP_STORE
            return VoiceKitLocalization.string("麦克风和语音识别授权后立即生效；键盘事件权限在系统设置中授权后，需要重启 VoiceKit 才会生效。")
#else
        if case .recommended = restartState {
            return VoiceKitLocalization.string("辅助功能刚授权，请使用上方的重启按钮；麦克风和语音识别权限通常不需要重启。")
        }
        return VoiceKitLocalization.string("只有辅助功能在刚授权后可能需要重启；麦克风和语音识别权限通常不需要重启。")
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

#if APP_STORE
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
#endif

#if !APP_STORE
    private var accessibilityStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        // 只信 AXIsProcessTrusted：曾经用「读取系统焦点元素」做兜底探测，
        // 但 App 查看自己的设置页时 VoiceKit 必定是前台 App，
        // 而读取自身 AX 树不需要辅助功能授权 → 探测恒成功，误报「已授权」。
        // 注意：AXIsProcessTrusted 的结果是进程级缓存，授权/撤销后需重启 App 才会刷新，
        // 这正是下方 restartRow 提示存在的原因。
        if PasteService.shared.isTrusted { return .granted }
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
        VoiceKitPermissionReloadState.make(
            distribution: distribution,
            accessibility: currentAccessibilityStatus,
            accessibilityRequested: restartRequested,
            postEventRequested: postEventRequestAttempted,
            postEventUsable: PasteService.shared.canPostEvents,
            postEventDismissed: postEventRestartDismissed
        )
    }

    /// App Store 版没有辅助功能路径，状态机里占位（不参与判定）。
    private var currentAccessibilityStatus: VoiceKitPermissionState {
#if APP_STORE
        .notDetermined
#else
        accessibilityStatus
#endif
    }

    private func permissionRow(icon: String, name: String, why: String, ifDenied: String, status: VoiceKitPermissionState, action: @escaping () -> Void) -> some View {
        let localizedName = VoiceKitLocalization.string(name)
        let localizedWhy = VoiceKitLocalization.string(why)
        let localizedIfDenied = VoiceKitLocalization.string(ifDenied)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(status == .granted ? VoiceKitSemanticColor.success : VoiceKitSemanticColor.secondaryText)
                    .frame(width: 24)
                Text(localizedName).font(typography.body).bold()
                Spacer()
                statusBadge(status)
                if status != .granted {
                    // App Review 5.1.1(iv)：授权弹窗前的按钮用「继续」这类中性文案；
                    // 已被拒绝时按钮的作用是跳转系统设置，如实标注。
                    Button(status == .notDetermined
                           ? VoiceKitLocalization.string("继续")
                           : VoiceKitLocalization.string("打开系统设置")) { action() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(localizedWhy)
                .font(typography.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status != .granted {
                Text(localizedIfDenied)
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

    private var restartRow: some View {
        let copy: (title: String, detail: String) = {
            if case .recommended(.postEvent) = restartState {
                return (
                    VoiceKitLocalization.string("自动写回将在重启后生效"),
                    VoiceKitLocalization.string("如果你刚刚在系统提示或系统设置中允许了键盘事件权限，VoiceKit 需要重启一次才能识别到新授权（系统缓存限制）。")
                )
            }
            return (
                VoiceKitLocalization.string("辅助功能已授权"),
                VoiceKitLocalization.string("重启 VoiceKit，让刚授权的直接写入能力完整生效。")
            )
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.title)
                    .font(typography.sectionTitle)
                Text(copy.detail)
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(VoiceKitLocalization.string("现在重启 VoiceKit")) {
                        restartApplication()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(VoiceKitLocalization.string("稍后处理")) {
                        dismissRestartRow()
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func dismissRestartRow() {
        if case .recommended(.postEvent) = restartState {
            postEventRestartDismissed = true
        } else {
            restartRequested = false
        }
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
                validationMessage = VoiceKitLocalization.string("阿里云 Fun-ASR 的 API Key 不能为空")
                showValidationAlert = true; return
            }
            if draft.asr.aliyun.workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = VoiceKitLocalization.string("阿里云 Fun-ASR 的 Workspace ID 不能为空")
                showValidationAlert = true; return
            }
        }
        // 讯飞：检查三要素必填
        if draft.asr.engine == "xunfei" {
            if draft.asr.xunfei.appId.trimmingCharacters(in: .whitespaces).isEmpty ||
                draft.asr.xunfei.apiKey.trimmingCharacters(in: .whitespaces).isEmpty ||
                draft.asr.xunfei.apiSecret.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = VoiceKitLocalization.string("讯飞听写的 AppID、APIKey、APISecret 不能为空")
                showValidationAlert = true; return
            }
        }
        // Deepgram：检查必填
        if draft.asr.engine == "deepgram" {
            if draft.asr.deepgram.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = VoiceKitLocalization.string("Deepgram 的 API Key 不能为空")
                showValidationAlert = true; return
            }
        }
        // LLM：检查选中模型是否存在且必填字段完整
        if draft.llm.enabled {
            guard let model = draft.llm.selectedModel else {
                validationMessage = VoiceKitLocalization.string("请先添加并选择一个 LLM 模型")
                showValidationAlert = true; return
            }
            if model.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = VoiceKitLocalization.format("模型「%@」的 Base URL 不能为空", model.name)
                showValidationAlert = true; return
            }
            if model.engine == "openai" && model.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = VoiceKitLocalization.format("模型「%@」的 API Key 不能为空", model.name)
                showValidationAlert = true; return
            }
            if model.model.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = VoiceKitLocalization.format("模型「%@」的模型名不能为空", model.name)
                showValidationAlert = true; return
            }
        }
        if let loginItemErr = ConfigStore.shared.update(draft) {
            validationMessage = VoiceKitLocalization.format("登录项设置失败：%@", loginItemErr)
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
        return VoiceKitLocalization.format("版本 %@ (build %@)", ver, build)
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
            .accessibilityLabel(VoiceKitLocalization.format("复制 %@", value))
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
private struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
