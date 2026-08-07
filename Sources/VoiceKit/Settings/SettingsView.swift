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

    // 模型管理
    @State private var showModelManagement = false
    @State private var showDiscardAlert = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("设置")
                    .font(typography.title)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                List(SettingsPane.allCases, selection: $selectedPane) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                        .padding(.leading, pane.isSubpane ? 16 : 0)
                }
                .listStyle(.sidebar)
                .font(typography.body)
            }
            .frame(width: 208)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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

                    paneContent
                        .padding(.horizontal, 30)
                        .padding(.top, 30)
                        .padding(.bottom, 30)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .font(typography.body)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 580)
        .voiceKitTextScale(selectedTextScale)
        .preferredColorScheme(selectedAppearance.colorScheme)
        .onAppear {
            selectedPane = SettingsPane.restored(from: selectedPaneRawValue)
            onTabChange(selectedPane.index)
        }
        .onChange(of: selectedPane) { _, newPane in
            selectedPaneRawValue = newPane.rawValue
            onTabChange(newPane.index)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { movePane(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(selectedPane.index == 0)
                .accessibilityLabel("上一个设置页面")

                Button { movePane(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(selectedPane.index == SettingsPane.allCases.count - 1)
                .accessibilityLabel("下一个设置页面")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("关闭") { closeSettings() }
                Button("保存") { save() }.disabled(!hasChanges)
            }
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
            PromptPreviewSheet(systemPrompt: draft.llm.prompt.system,
                               userTemplate: draft.llm.prompt.user,
                               language: draft.asr.system.language,
                               engine: draft.llm.selectedModel?.engine ?? "openai")
        }
        .sheet(isPresented: $showLLMTest) {
            LLMTestSheet(llmConfig: draft.llm, language: draft.asr.system.language)
        }
        .sheet(isPresented: $showModelManagement) {
            ModelManagementSheet(
                models: $draft.llm.models,
                selectedModelID: $draft.llm.selectedModelID,
                temperature: draft.llm.temperature
            )
        }
    }

    private var selectedTextScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: selectedTextScale)
    }

    private var selectedAppearance: VoiceKitAppearance {
        VoiceKitAppearance.restored(from: appearanceRawValue)
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
        VStack(alignment: .leading, spacing: 14) {
            section("全局热键") {
                HotkeyRecorder(hotkeyString: $draft.general.hotkey).frame(width: 280, height: 24)
            }
            Toggle("登录时启动", isOn: $draft.general.launchAtStartup)
            Toggle("启动时显示设置窗口", isOn: $draft.general.showSettingsOnLaunch)
            HStack {
                Text("保留历史").font(typography.callout).foregroundStyle(.secondary)
                Picker("", selection: $draft.general.maxHistoryCount) {
                    Text("20 条").tag(20); Text("50 条").tag(50)
                    Text("100 条").tag(100); Text("200 条").tag(200)
                }.labelsHidden().frame(width: 140)
            }

            section("界面") {
                Picker("外观", selection: $appearanceRawValue) {
                    ForEach(VoiceKitAppearance.allCases, id: \.rawValue) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Picker("文字大小", selection: $textScaleRawValue) {
                    ForEach(VoiceKitTextScale.allCases, id: \.rawValue) { scale in
                        Text(scale.title).tag(scale.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Text("默认使用 macOS 系统字体；较大和更大只调整 VoiceKit 的界面文字，不改变系统设置。")
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("声音").font(typography.sectionTitle)
            Toggle("播放提示音", isOn: $draft.general.sound.enabled)
            if draft.general.sound.enabled {
                HStack {
                    Text("开始录音").font(typography.callout).foregroundStyle(.secondary)
                    Picker("", selection: $draft.general.sound.startSound) {
                        ForEach(Self.systemSounds, id: \.0) { n, l in Text(l).tag(n) }
                    }.labelsHidden().frame(width: 140)
                }
                HStack {
                    Text("识别完成").font(typography.callout).foregroundStyle(.secondary)
                    Picker("", selection: $draft.general.sound.stopSound) {
                        ForEach(Self.systemSounds, id: \.0) { n, l in Text(l).tag(n) }
                    }.labelsHidden().frame(width: 140)
                }
                HStack(spacing: 8) {
                    Button("试听开始") { NSSound(named: .init(draft.general.sound.startSound))?.play() }
                    Button("试听完成") { NSSound(named: .init(draft.general.sound.stopSound))?.play() }
                }
            }

        }
    }

    // MARK: - 语音识别

    private var asrTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("引擎") {
                Picker("", selection: $draft.asr.engine) {
                    Text("系统听写").tag("system")
                    Text("阿里云 Fun-ASR").tag("aliyun")
                }.labelsHidden().frame(width: 200)
            }
            Text("macOS 内置语音识别，免费无需联网。阿里云高精度自动标点，需配置 API Key。")
                .font(typography.callout).foregroundStyle(.secondary)

            section("识别语言") {
                Picker("", selection: $draft.asr.system.language) {
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
                }.labelsHidden().frame(width: 180)
            }
            Text("选择你说什么语言，偶尔夹带外文单词也能识别")
                .font(typography.callout).foregroundStyle(.secondary)

            // 阿里云专属配置
            if draft.asr.engine == "aliyun" {
                Divider()
                Text("阿里云 Fun-ASR 配置").font(typography.sectionTitle)

                Toggle("语义断句", isOn: $draft.asr.aliyun.semanticPunctuation)
                Text("开启：AI 语义模型自动加标点，结果更自然。关闭：仅靠停顿分割。")
                    .font(typography.callout).foregroundStyle(.secondary)
                if !draft.asr.aliyun.semanticPunctuation {
                    section("停顿时长") {
                        HStack {
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

                section("VAD 灵敏度") {
                    HStack {
                        Slider(value: $draft.asr.aliyun.speechNoiseThreshold, in: -1...1, step: 0.1)
                        Text(String(format: "%+.1f", draft.asr.aliyun.speechNoiseThreshold))
                            .font(typography.callout).frame(width: 40, alignment: .trailing)
                    }
                    Text("控制语音/静音判定灵敏度。负值更敏感（更容易判定为语音），正值更保守（更容易判定为静音）。")
                        .font(typography.callout).foregroundStyle(.secondary)
                }

                Divider()
                Toggle("静音自动停止", isOn: $draft.asr.aliyun.autoStopEnabled)
                Text("开启后，说话停顿超过设定时间会自动结束听写并粘贴，不用再按一次热键")
                    .font(typography.callout).foregroundStyle(.secondary)
                if draft.asr.aliyun.autoStopEnabled {
                    section("静音阈值") {
                        HStack {
                            Slider(value: $draft.asr.aliyun.autoStopThreshold, in: 0.005...0.1, step: 0.005)
                            Text(String(format: "%.3f", draft.asr.aliyun.autoStopThreshold))
                                .font(typography.callout).frame(width: 45, alignment: .trailing)
                        }
                        Text("音频电平低于此值视为静音。值越小判定越严格（需要更安静的环境）。")
                            .font(typography.callout).foregroundStyle(.secondary)
                    }
                    section("超时时间") {
                        HStack {
                            Slider(value: $draft.asr.aliyun.autoStopTimeout, in: 1...10, step: 0.5)
                            Text(String(format: "%.1fs", draft.asr.aliyun.autoStopTimeout))
                                .font(typography.callout).frame(width: 40, alignment: .trailing)
                        }
                        Text("连续静音超过此时长后自动停止听写。")
                            .font(typography.callout).foregroundStyle(.secondary)
                    }
                }

                Divider()
                section("API Key") {
                    HStack(spacing: 4) {
                        if showAPIKey {
                            TextField("sk-...", text: $draft.asr.aliyun.apiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-...", text: $draft.asr.aliyun.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showAPIKey.toggle() }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showAPIKey ? "隐藏 API Key" : "显示 API Key")
                    }.frame(maxWidth: 380)
                }
                section("Workspace ID") {
                    TextField("ws-...", text: $draft.asr.aliyun.workspaceId)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                }
                section("区域") {
                    TextField("cn-beijing", text: $draft.asr.aliyun.region)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                section("模型") {
                    TextField("fun-asr-realtime", text: $draft.asr.aliyun.model)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .topLeading)
    }

    // MARK: - AI 服务总览

    private var aiServiceOverviewTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("AI 润色总览")
                            .font(typography.title)
                        Spacer()
                        Label(draft.llm.enabled ? "已启用" : "未启用",
                              systemImage: draft.llm.enabled ? "checkmark.circle.fill" : "pause.circle")
                            .font(typography.callout)
                            .foregroundStyle(draft.llm.enabled ? VoiceKitSemanticColor.success : .secondary)
                    }
                    Text("识别完成后，VoiceKit 可以把语音结果发送到你配置的 AI 模型进行整理、补标点和口语改写。AI 润色不会改变语音识别引擎本身。")
                        .font(typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("启用 AI 润色", isOn: $draft.llm.enabled)
                }
                .padding(8)
            }

            GroupBox("工作方式") {
                VStack(alignment: .leading, spacing: 10) {
                    overviewStep("1", title: "先完成语音识别", detail: "语音由当前选择的系统听写或阿里云 Fun-ASR 处理。")
                    overviewStep("2", title: "再调用你的模型", detail: "文本只发送到你在模型管理中配置的服务；VoiceKit 没有自己的中转 API。")
                    overviewStep("3", title: "最后写回输入位置", detail: "润色结果和原始识别结果都会保留在历史记录中。")
                }
                .padding(8)
            }

            HStack(spacing: 10) {
                Button("模型管理") { selectedPane = .models }
                    .buttonStyle(.borderedProminent)
                Button("提示词管理") { selectedPane = .prompts }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 16) {
            section("当前模型") {
                HStack(spacing: 8) {
                    Picker("", selection: $draft.llm.selectedModelID) {
                        if draft.llm.models.isEmpty { Text("未配置模型").tag("") }
                        ForEach(draft.llm.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    Button("编辑模型列表") { showModelManagement = true }
                        .buttonStyle(.bordered)
                }
                if draft.llm.models.isEmpty {
                    Text("还没有模型。你可以添加云端 API 或本地 Ollama 模型。")
                        .font(typography.callout).foregroundStyle(.secondary)
                } else if let model = draft.llm.selectedModel {
                    Text("引擎：\(model.engine)  ·  模型：\(model.model)")
                        .font(typography.callout).foregroundStyle(.secondary)
                }
            }

            section("输出行为") {
                HStack {
                    Slider(value: $draft.llm.temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", draft.llm.temperature))
                        .font(typography.callout).frame(width: 30)
                }
                Text("温度越高越随机；越低越稳定。语音润色建议使用 0.3 到 0.7。")
                    .font(typography.callout).foregroundStyle(.secondary)
            }

            LLMConnectivityTest(llmConfig: draft.llm)

            if let model = draft.llm.selectedModel, model.engine == "openai" {
                Toggle("深度思考 (thinking)", isOn: thinkingBinding)
                Text("部分模型支持，启用后先深度推理再输出。请确保所选模型支持此功能。")
                    .font(typography.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("提示词决定 AI 如何整理识别结果。保留 {{input}} 占位符，运行时会替换为原始语音文本。")
                .font(typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            section("系统提示词") {
                TextEditor(text: $draft.llm.prompt.system)
                    .font(typography.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }

            section("用户模板") {
                TextEditor(text: $draft.llm.prompt.user)
                    .font(typography.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Button("预览提示词") { showPromptPreview = true }
                Button("测试润色效果") { showLLMTest = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - 权限

    private var permissionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这些权限只用于录音、语音识别和把结果送回当前输入位置。你可以随时在系统设置中撤销。")
                .font(typography.callout).foregroundStyle(.secondary)
            
            // 麦克风
            permissionCard(
                icon: "mic.fill",
                name: "麦克风",
                why: "听到你的声音，才能转成文字",
                ifDenied: "不授权：无法使用语音输入",
                status: micStatus,
                action: requestMicPermission
            )

            // 语音识别
            permissionCard(
                icon: "text.bubble.fill",
                name: "语音识别",
                why: "把你说的话实时转写成文字",
                ifDenied: "不授权：无法使用语音输入",
                status: speechStatus,
                action: requestSpeechPermission
            )

            // 合成键盘事件（App Store 版和官网版的剪贴板回退路径都需要）
            permissionCard(
                icon: "keyboard.fill",
                name: "自动写回（键盘事件）",
                why: "允许 VoiceKit 在识别完成后尝试发送一次 ⌘V",
                ifDenied: "不授权：文字仍会保留在剪贴板，请手动按 ⌘V",
                status: postEventStatus,
                action: requestPostEventPermission
            )

            // 辅助功能（仅官网版）
#if !APP_STORE
            permissionCard(
                icon: "rectangle.and.hand.point.up.left.fill",
                name: "辅助功能（直接写入）",
                why: "允许 VoiceKit 直接访问目标输入框写入文字",
                ifDenied: "不授权：会回退到剪贴板，请手动按 ⌘V",
                status: accessibilityStatus,
                action: requestAccessibilityPermission
            )
#endif

#if !APP_STORE
            if restartState == .recommended {
                restartCard
            }
#endif

            Divider()

            VStack(alignment: .leading, spacing: 6) {
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
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
            )
            
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // 从系统设置返回 App 时刷新权限状态，保证授权结果立即反映到界面
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshID = UUID()
        }
    }

    // MARK: - 数据隐私

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("你决定数据去哪里", systemImage: "arrow.triangle.branch")
                        .font(typography.sectionTitle)

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
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("VoiceKit 不提供中转服务", systemImage: "hand.raised.fill")
                        .font(typography.sectionTitle)
                    Text("除了你自己配置的语音识别和 AI 服务，VoiceKit 不调用其他 API 服务。没有后台服务器，不收集语音或文字，不统计使用情况，也不追踪用户行为。")
                        .font(typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("API Key、模型地址和提示词只保存在本机配置中，并按你的设置使用。")
                        .font(typography.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func permissionCard(icon: String, name: String, why: String, ifDenied: String, status: VoiceKitPermissionState, action: @escaping () -> Void) -> some View {
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
                        .controlSize(.small)
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(status == .granted ? Color.green.opacity(0.05) : Color.orange.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(status == .granted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), lineWidth: 1)
        )
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
    private var restartCard: some View {
        GroupBox {
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
                        .controlSize(.small)

                        Button("稍后处理") {
                            restartRequested = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(4)
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
#endif

    // MARK: - 布局辅助

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(typography.sectionTitle)
                .foregroundStyle(.primary)
            content()
        }
    }

    private func movePane(by offset: Int) {
        let panes = SettingsPane.allCases
        guard let nextIndex = panes.firstIndex(of: selectedPane).map({ $0 + offset }),
              panes.indices.contains(nextIndex) else { return }
        selectedPane = panes[nextIndex]
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
        VStack(alignment: .leading, spacing: 20) {
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

            Divider()

            // 开源声明
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("开源免费 · 无需注册", systemImage: "lock.open")
                        .font(typography.sectionTitle)
                    Text("VoiceKit 是完全开源的软件，代码托管在 GitHub，任何人都可以查看、审计和参与改进。没有付费墙，没有隐藏费用，也不需要注册任何账号。")
                        .font(typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 联系与更新
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("联系与更新", systemImage: "envelope")
                        .font(typography.sectionTitle)
                    
                    contactRow(icon: "envelope.fill", value: ContactInfo.email)
                    contactRow(icon: "safari.fill", value: ContactInfo.website)
                    contactRow(icon: "chevron.left.forwardslash.chevron.right", value: ContactInfo.github)
                    Text("链接仅作为信息展示；使用右侧复制按钮后，可在浏览器或邮件客户端中使用。")
                        .font(typography.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            Text("Copyright © 2026 VoiceKit. MIT License.")
                .font(typography.metadata).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            let tmpl = PromptTemplate(system: llmConfig.prompt.system, user: llmConfig.prompt.user)
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

// MARK: - LLM 连接测试

private struct LLMConnectivityTest: View {
    let llmConfig: LLMConfig

    @State private var status: Status = .idle
    @Environment(\.voiceKitTextScale) private var textScale

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    private enum Status: Equatable {
        case idle, testing, success, failure(String)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button("测试连接") {
                runTest()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(status == .testing || llmConfig.selectedModel == nil)

            if status == .testing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("连接中…")
                    .font(typography.metadata).foregroundStyle(.secondary)
            }

            switch status {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Text("连接成功")
                    .font(typography.metadata).foregroundStyle(.green)
            case .failure(let msg):
                Image(systemName: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                Text(msg)
                    .font(typography.metadata).foregroundStyle(.red)
                    .lineLimit(1)
            default:
                EmptyView()
            }

            Spacer()
        }
    }

    private func runTest() {
        guard let model = llmConfig.selectedModel else { return }
        status = .testing
        Task {
            let engine = AppCoordinator.buildLLMEngine(from: model, temperature: llmConfig.temperature)
            let ok = await engine.checkConnectivity()
            await MainActor.run {
                status = ok ? .success : .failure("无法连接，请检查 URL 和网络")
            }
        }
    }
}

// MARK: - 模型管理 Sheet（Table + 批量测试）

private struct ModelManagementSheet: View {
    @Binding var models: [LLMModelDef]
    @Binding var selectedModelID: String
    let temperature: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale
    @State private var editingModel: LLMModelDef?
    @State private var showDeleteConfirm = false
    @State private var modelToDelete: LLMModelDef?

    // 批量测试
    @State private var testingResults: [String: TestRowResult] = [:]
    @State private var isTesting = false
    @State private var testedCount = 0

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    struct TestRowResult {
        var success: Bool
        var latencyMs: Int?
        var tokensUsed: Int
        var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("管理模型").font(typography.sectionTitle)

            if models.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("暂无模型，点击下方按钮添加").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(of: ModelRow.self) {
                    TableColumn("名称", value: \.name).width(min: 80)
                    TableColumn("引擎") { row in
#if APP_STORE
                        Text(row.engine == "openai" ? "云端 API" : "Ollama")
                            .foregroundStyle(.secondary)
#else
                        Text(row.engine == "openai" ? "OpenAI" : "Ollama")
                            .foregroundStyle(.secondary)
#endif
                    }.width(60)
                    TableColumn("模型", value: \.modelName).width(min: 100)
                    TableColumn("Token") { row in
                        Text("\(row.totalTokens)").foregroundStyle(.secondary)
                    }.width(50)
                    TableColumn("次数") { row in
                        Text("\(row.usageCount)").foregroundStyle(.secondary)
                    }
                    TableColumn("测试") { row in
                        if let result = testingResults[row.id] {
                            if result.success {
                                Text("\(result.latencyMs ?? 0)ms")
                                    .foregroundStyle(.green)
                            } else {
                                Text(result.error ?? "失败")
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("-").foregroundStyle(.tertiary)
                        }
                    }
                    TableColumn("") { row in
                        HStack(spacing: 8) {
                            if row.id == selectedModelID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            Button("编辑") {
                                if let m = models.first(where: { $0.id == row.id }) {
                                    editingModel = m
                                }
                            }
                            .buttonStyle(.plain).font(typography.metadata).foregroundStyle(.tint)
                            Button("删除") {
                                if let m = models.first(where: { $0.id == row.id }) {
                                    modelToDelete = m
                                    showDeleteConfirm = true
                                }
                            }
                            .buttonStyle(.plain).font(typography.metadata).foregroundStyle(.red)
                        }
                    }
                } rows: {
                    ForEach(models) { model in
                        TableRow(ModelRow(
                            id: model.id,
                            name: model.name,
                            engine: model.engine,
                            modelName: model.model,
                            totalTokens: model.totalTokens,
                            usageCount: model.usageCount
                        ))
                    }
                }
                .frame(minHeight: 200)

                if isTesting {
                    HStack {
                        ProgressView().scaleEffect(0.6)
                        Text("测试中… (\(testedCount)/\(models.count))")
                            .font(typography.callout).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button(action: {
#if APP_STORE
                    editingModel = LLMModelDef(name: "", engine: "openai", baseUrl: "", apiKey: "", model: "")
#else
                    editingModel = LLMModelDef(name: "", engine: "openai", baseUrl: "https://api.openai.com/v1", apiKey: "", model: "gpt-4o-mini")
#endif
                }) {
                    Label("添加模型", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(action: { runBatchTest() }) {
                    Label("批量测试", systemImage: "gauge.with.dots.needle.33percent")
                }
                .buttonStyle(.bordered)
                .disabled(models.isEmpty || isTesting)

                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 800, height: 500)
        .sheet(item: $editingModel) { model in
            ModelEditorSheet(
                model: model,
                onSave: { saved in
                    if let idx = models.firstIndex(where: { $0.id == saved.id }) {
                        models[idx] = saved
                    } else {
                        models.append(saved)
                        if selectedModelID.isEmpty { selectedModelID = saved.id }
                    }
                    editingModel = nil
                },
                onCancel: { editingModel = nil }
            )
        }
        .alert("删除模型？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let m = modelToDelete {
                    models.removeAll { $0.id == m.id }
                    if selectedModelID == m.id {
                        selectedModelID = models.first?.id ?? ""
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(modelToDelete?.name ?? "")」吗？此操作不可撤销。")
        }
    }

    private func runBatchTest() {
        guard !isTesting else { return }
        isTesting = true
        testedCount = 0
        testingResults = [:]

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
                        testingResults[model.id] = TestRowResult(success: true, latencyMs: elapsed, tokensUsed: tokens)
                        testedCount += 1
                        if tokens > 0 {
                            ConfigStore.shared.addLLMTokenUsage(modelID: model.id, tokens: tokens)
                        }
                    }
                } catch {
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    await MainActor.run {
                        testingResults[model.id] = TestRowResult(success: false, latencyMs: elapsed, tokensUsed: 0, error: error.localizedDescription)
                        testedCount += 1
                    }
                }
            }
            await MainActor.run { isTesting = false }
        }
    }

    struct ModelRow: Identifiable {
        let id: String
        let name: String
        let engine: String
        let modelName: String
        let totalTokens: Int
        let usageCount: Int
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
                .labelsHidden().frame(width: 220)
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
