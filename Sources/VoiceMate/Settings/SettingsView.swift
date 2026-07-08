import SwiftUI
import AVFoundation
import Speech

struct SettingsView: View {
    var onDone: () -> Void = {}

    @State private var draft: AppConfig = ConfigStore.shared.config
    /// 打开设置时的原始配置，用于判断是否有未保存变更
    @State private var originalConfig: AppConfig = ConfigStore.shared.config
    @State private var selectedTab = 0
    @State private var showAPIKey = false
    @State private var permissionRefreshID = UUID()

    // 保存校验
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    // 提示词预览
    @State private var showPromptPreview = false

    // LLM 润色测试
    @State private var showLLMTest = false
    @State private var llmTestInput = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("常规").tag(0)
                Text("语音识别").tag(1)
                Text("AI 润色").tag(2)
                Text("关于").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.top, 12)

            ScrollView {
                VStack(spacing: 0) {
                    // 未保存变更提示条
                    if hasChanges {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.caption2)
                            Text("有未保存的变更")
                                .font(.caption2)
                        }
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08))
                    }

                    Group {
                        switch selectedTab {
                        case 0: generalTab
                        case 1: asrTab
                        case 2: llmTab
                        case 3: aboutTab
                        default: EmptyView()
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 560, height: 620)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!hasChanges) }
            ToolbarItem(placement: .cancellationAction) { Button("取消") { onDone() } }
        }
        .alert("保存失败", isPresented: $showValidationAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
        .sheet(isPresented: $showPromptPreview) {
            PromptPreviewSheet(systemPrompt: draft.llm.prompt.system,
                               userTemplate: draft.llm.prompt.user,
                               language: draft.asr.system.language,
                               engine: draft.llm.engine)
        }
        .sheet(isPresented: $showLLMTest) {
            LLMTestSheet(llmConfig: draft.llm, language: draft.asr.system.language)
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
                Text("保留历史").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $draft.general.maxHistoryCount) {
                    Text("20 条").tag(20); Text("50 条").tag(50)
                    Text("100 条").tag(100); Text("200 条").tag(200)
                }.labelsHidden().frame(width: 140)
            }

            Divider()
            Text("声音").font(.headline)
            Toggle("播放提示音", isOn: $draft.general.sound.enabled)
            if draft.general.sound.enabled {
                HStack {
                    Text("开始录音").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.general.sound.startSound) {
                        ForEach(Self.systemSounds, id: \.0) { n, l in Text(l).tag(n) }
                    }.labelsHidden().frame(width: 140)
                }
                HStack {
                    Text("识别完成").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.general.sound.stopSound) {
                        ForEach(Self.systemSounds, id: \.0) { n, l in Text(l).tag(n) }
                    }.labelsHidden().frame(width: 140)
                }
                HStack(spacing: 8) {
                    Button("试听开始") { NSSound(named: .init(draft.general.sound.startSound))?.play() }
                    Button("试听完成") { NSSound(named: .init(draft.general.sound.stopSound))?.play() }
                }
            }

            Divider()
            HStack {
                Text("权限状态").font(.headline)
                Spacer()
                Button("刷新") { permissionRefreshID = UUID() }.buttonStyle(.plain).font(.caption)
            }
            Text("如果粘贴功能已正常，则辅助功能实际已授权，显示状态可能有延迟。")
                .font(.caption2).foregroundStyle(.tertiary)
            permissionRow(icon: "mic", name: "麦克风",
                reason: "语音识别需要采集音频输入",
                status: micStatus, action: { PasteService.shared.openMicrophoneSettings() })
            permissionRow(icon: "text.bubble", name: "语音识别",
                reason: "将语音实时转为文字",
                status: speechStatus, action: { PasteService.shared.openSpeechSettings() })
            permissionRow(icon: "accessibility", name: "辅助功能",
                reason: "将识别结果自动粘贴到目标 app",
                status: accessibilityStatus, action: { PasteService.shared.openAccessibilitySettings() })
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
                .font(.caption2).foregroundStyle(.tertiary)

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
                .font(.caption2).foregroundStyle(.tertiary)

            // 阿里云专属配置
            if draft.asr.engine == "aliyun" {
                Divider()
                Text("阿里云 Fun-ASR 配置").font(.headline)

                Toggle("语义断句", isOn: $draft.asr.aliyun.semanticPunctuation)
                Text("开启：AI 语义模型自动加标点，结果更自然。关闭：仅靠停顿分割。")
                    .font(.caption2).foregroundStyle(.tertiary)
                if !draft.asr.aliyun.semanticPunctuation {
                    section("停顿时长") {
                        HStack {
                            Slider(value: Binding(get: { Double(draft.asr.aliyun.maxSentenceSilence) },
                                                   set: { draft.asr.aliyun.maxSentenceSilence = Int($0) }),
                                   in: 200...6000, step: 100)
                            Text("\(draft.asr.aliyun.maxSentenceSilence)ms")
                                .font(.caption).frame(width: 55, alignment: .trailing)
                        }
                        Text("说话停顿超过此时长则断句。值越小断句越频繁。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                section("VAD 灵敏度") {
                    HStack {
                        Slider(value: $draft.asr.aliyun.speechNoiseThreshold, in: -1...1, step: 0.1)
                        Text(String(format: "%+.1f", draft.asr.aliyun.speechNoiseThreshold))
                            .font(.caption).frame(width: 40, alignment: .trailing)
                    }
                    Text("控制语音/静音判定灵敏度。负值更敏感（更容易判定为语音），正值更保守（更容易判定为静音）。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Divider()
                Toggle("静音自动停止", isOn: $draft.asr.aliyun.autoStopEnabled)
                Text("开启后，说话停顿超过设定时间会自动结束听写并粘贴，不用再按一次热键")
                    .font(.caption2).foregroundStyle(.tertiary)
                if draft.asr.aliyun.autoStopEnabled {
                    section("静音阈值") {
                        HStack {
                            Slider(value: $draft.asr.aliyun.autoStopThreshold, in: 0.005...0.1, step: 0.005)
                            Text(String(format: "%.3f", draft.asr.aliyun.autoStopThreshold))
                                .font(.caption).frame(width: 45, alignment: .trailing)
                        }
                        Text("音频电平低于此值视为静音。值越小判定越严格（需要更安静的环境）。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    section("超时时间") {
                        HStack {
                            Slider(value: $draft.asr.aliyun.autoStopTimeout, in: 1...10, step: 0.5)
                            Text(String(format: "%.1fs", draft.asr.aliyun.autoStopTimeout))
                                .font(.caption).frame(width: 40, alignment: .trailing)
                        }
                        Text("连续静音超过此时长后自动停止听写。")
                            .font(.caption2).foregroundStyle(.tertiary)
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
                        }.buttonStyle(.plain)
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

    // MARK: - AI 润色

    private var llmTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("启用润色", isOn: $draft.llm.enabled)

            Group {
                section("引擎") {
                    Picker("", selection: $draft.llm.engine) {
                        Text("OpenAI 协议").tag("openai")
                        Text("Ollama（本地）").tag("ollama")
                    }.labelsHidden().frame(width: 220)
                }
                Text("OpenAI 协议适用于 OpenAI / DeepSeek / 阿里云百炼 / Groq 等。Ollama 需本地先启动。")
                    .font(.caption2).foregroundStyle(.tertiary)

                llmFields

                section("温度") {
                    HStack {
                        Slider(value: llmTemperature, in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", llmTemperature.wrappedValue))
                            .font(.caption).frame(width: 30)
                    }
                    Text("越高输出越随机、有创意；越低越保守、确定性高。润色建议 0.3~0.7。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                // 连接测试
                LLMConnectivityTest(llmConfig: draft.llm)

                if draft.llm.engine == "openai" {
                    Toggle("深度思考 (thinking)", isOn: Binding(
                        get: { draft.llm.openai.model.contains("thinking") || draft.llm.openai.model.contains("qwq") },
                        set: { v in
                            if v {
                                if !draft.llm.openai.model.contains("thinking") && !draft.llm.openai.model.contains("qwq") {
                                    draft.llm.openai.model += "-thinking"
                                }
                            } else {
                                draft.llm.openai.model = draft.llm.openai.model
                                    .replacingOccurrences(of: "-thinking", with: "")
                                    .replacingOccurrences(of: "qwq-plus", with: "qwen-plus")
                            }
                        }
                    ))
                    Text("部分模型支持，启用后先深度推理再输出。请确保所选模型支持此功能。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Divider()

                section("系统提示词") {
                    TextField("系统角色描述", text: $draft.llm.prompt.system, axis: .vertical)
                        .textFieldStyle(.roundedBorder).frame(minHeight: 60)
                }
                section("用户模板") {
                    TextField("口语内容：{{input}}\n\n改写结果：", text: $draft.llm.prompt.user, axis: .vertical)
                        .textFieldStyle(.roundedBorder).frame(minHeight: 60)
                }
                Text("{{input}} 会被替换为识别文本").font(.caption2).foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button("预览提示词") { showPromptPreview = true }
                    Button("测试润色效果") { llmTestInput = ""; showLLMTest = true }
                }
            }
            .disabled(!draft.llm.enabled)
            .opacity(draft.llm.enabled ? 1 : 0.35)
        }
    }

    @ViewBuilder
    private var llmFields: some View {
        section("Base URL") {
            Group {
                if draft.llm.engine == "openai" {
                    TextField("https://api.openai.com/v1", text: $draft.llm.openai.baseUrl)
                } else {
                    TextField("http://localhost:11434", text: $draft.llm.ollama.baseUrl)
                }
            }
            .textFieldStyle(.roundedBorder).frame(maxWidth: 380)
        }

        section("API Key") {
            SecureField("sk-...", text: $draft.llm.openai.apiKey)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 380)
        }
        .opacity(draft.llm.engine == "openai" ? 1 : 0.2)

        section("模型") {
            Group {
                if draft.llm.engine == "openai" {
                    TextField("gpt-4o-mini", text: $draft.llm.openai.model)
                } else {
                    TextField("qwen2.5:7b", text: $draft.llm.ollama.model)
                }
            }
            .textFieldStyle(.roundedBorder).frame(width: 220)
        }
    }

    // MARK: - 权限

    private enum PermissionStatus { case granted, denied, notDetermined }

    private var micStatus: PermissionStatus {
        _ = permissionRefreshID
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var speechStatus: PermissionStatus {
        _ = permissionRefreshID
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private var accessibilityStatus: PermissionStatus {
        _ = permissionRefreshID
        if PasteService.shared.isTrusted { return .granted }
        let elem = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(elem, kAXFocusedUIElementAttribute as CFString, &focused)
        if result == .success { return .granted }
        return .notDetermined
    }

    private func permissionRow(icon: String, name: String, reason: String, status: PermissionStatus, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge(status)
            if status != .granted {
                Button("打开") { action() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func statusBadge(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .denied:
            Label("已拒绝", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .notDetermined:
            Label("未授权", systemImage: "questionmark.circle").foregroundStyle(.orange).font(.caption)
        }
    }

    // MARK: - 布局辅助

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
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
        if draft.llm.enabled && draft.llm.engine == "openai" {
            if draft.llm.openai.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "OpenAI 协议的 Base URL 不能为空"
                showValidationAlert = true; return
            }
            if draft.llm.openai.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "OpenAI 协议的 API Key 不能为空"
                showValidationAlert = true; return
            }
            if draft.llm.openai.model.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "OpenAI 协议的模型名不能为空"
                showValidationAlert = true; return
            }
        }
        if draft.llm.enabled && draft.llm.engine == "ollama" {
            if draft.llm.ollama.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "Ollama 的 Base URL 不能为空"
                showValidationAlert = true; return
            }
            if draft.llm.ollama.model.trimmingCharacters(in: .whitespaces).isEmpty {
                validationMessage = "Ollama 的模型名不能为空"
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
        onDone()
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题 + 图标
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceMate").font(.title2).bold()
                    Text("macOS 语音输入助手")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(aboutVersionString)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Divider()

            GroupBox("开源声明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VoiceMate 是完全开源的软件，代码托管在 GitHub，接受社区审计。")
                        .font(.callout)
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                        Text("https://github.com/gccyk-futur/voice-input")
                            .font(.caption).foregroundStyle(.tint)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("隐私与安全") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.caption).foregroundStyle(.green)
                        Text("打包使用 Apple Developer ID 签名，安全可靠，可直接安装使用。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "hand.raised")
                            .font(.caption).foregroundStyle(.green)
                        Text("软件**不收集任何隐私数据**。ASR 语音识别和 LLM 润色均使用用户自行配置的 API Key 直连对应服务，数据不经由任何第三方中转。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption).foregroundStyle(.green)
                        Text("软件本身没有网络服务、没有遥测、没有统计数据上报。所有网络请求均由用户配置的 ASR/LLM 服务触发。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            Text("Copyright © 2026 VoiceMate. MIT License.")
                .font(.caption2).foregroundStyle(.tertiary)
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

    private var llmTemperature: Binding<Double> {
        switch draft.llm.engine {
        case "ollama": return $draft.llm.ollama.temperature
        case "openai": return $draft.llm.openai.temperature
        default: return .constant(0.7)
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

    var body: some View {
        let tmpl = PromptTemplate(system: systemPrompt, user: userTemplate)
        let (sys, usr) = tmpl.render(input: "今天天气真好我们出去走走吧", language: language, engine: engine)

        VStack(alignment: .leading, spacing: 12) {
            Text("提示词预览").font(.headline)
            Text("示例输入：「今天天气真好我们出去走走吧」").font(.caption).foregroundStyle(.secondary)

            GroupBox("系统提示词") {
                ScrollView { Text(sys).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
            GroupBox("用户消息") {
                ScrollView { Text(usr).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
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
    @State private var inputText = ""
    @State private var resultText = ""
    @State private var isRunning = false
    @State private var errorMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("测试润色效果").font(.headline)
            Text("输入一段口语文本，测试 LLM 润色后的输出效果").font(.caption).foregroundStyle(.secondary)

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
                Text(err).font(.caption).foregroundStyle(.red)
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func runTest() {
        isRunning = true
        errorMsg = nil
        resultText = ""
        let text = inputText.trimmingCharacters(in: .whitespaces)
        let cfg = llmConfig

        Task {
            let tmpl = PromptTemplate(system: cfg.prompt.system, user: cfg.prompt.user)
            let (sys, usr) = tmpl.render(input: text, language: language, engine: cfg.engine)

            do {
                let engine: any LLMEngine = switch cfg.engine {
                case "ollama": OllamaEngine(config: cfg.ollama)
                default: OpenAICompatibleEngine(baseUrl: cfg.openai.baseUrl, apiKey: cfg.openai.apiKey, model: cfg.openai.model, temperature: cfg.openai.temperature, kind: .openai)
                }
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
            .disabled(status == .testing)

            if status == .testing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("连接中…")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            switch status {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Text("连接成功")
                    .font(.caption2).foregroundStyle(.green)
            case .failure(let msg):
                Image(systemName: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                Text(msg)
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(1)
            default:
                EmptyView()
            }

            Spacer()
        }
    }

    private func runTest() {
        status = .testing
        Task {
            let engine: any LLMEngine = switch llmConfig.engine {
            case "ollama": OllamaEngine(config: llmConfig.ollama)
            default: OpenAICompatibleEngine(
                baseUrl: llmConfig.openai.baseUrl,
                apiKey: llmConfig.openai.apiKey,
                model: llmConfig.openai.model,
                temperature: llmConfig.openai.temperature,
                kind: .openai
            )
            }
            let ok = await engine.checkConnectivity()
            await MainActor.run {
                status = ok ? .success : .failure("无法连接，请检查 URL 和网络")
            }
        }
    }
}
