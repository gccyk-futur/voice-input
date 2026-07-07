import SwiftUI

struct SettingsView: View {
    var onDone: () -> Void = {}

    @State private var draft: AppConfig = .default
    @State private var selectedTab = 0
    @State private var showAPIKey = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("常规").tag(0)
                Text("语音识别").tag(1)
                Text("AI 润色").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.top, 12)

            ScrollView {
                Group {
                    switch selectedTab {
                    case 0: generalTab
                    case 1: asrTab
                    case 2: llmTab
                    default: EmptyView()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 540, height: 460)
        .task { draft = ConfigStore.shared.config }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存") { persist() } }
            ToolbarItem(placement: .cancellationAction) { Button("取消") { onDone() } }
        }
    }

    // MARK: - 常规

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("全局热键") {
                HotkeyRecorder(hotkeyString: $draft.general.hotkey).frame(width: 280, height: 24)
            }
            Toggle("登录时启动", isOn: $draft.general.launchAtStartup)
            HStack {
                Text("保留历史").frame(width: 80, alignment: .leading)
                Picker("", selection: $draft.general.maxHistoryCount) {
                    Text("20 条").tag(20); Text("50 条").tag(50)
                    Text("100 条").tag(100); Text("200 条").tag(200)
                }.labelsHidden().frame(width: 120)
            }
        }
    }

    // MARK: - 语音识别

    private var asrTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("引擎") {
                Picker("", selection: $draft.asr.engine) {
                    Text("系统听写").tag("system")
                    Text("阿里云 Fun-ASR").tag("aliyun")
                }.labelsHidden().frame(width: 220)
            }
            HStack {
                Text("源语言").frame(width: 80, alignment: .leading)
                Picker("", selection: $draft.asr.system.language) {
                    Text("中文").tag("zh-Hans-CN")
                    Text("英文").tag("en-US")
                    Text("日语").tag("ja-JP")
                    Text("自动").tag("auto")
                }.labelsHidden().frame(width: 140)
            }
            HStack {
                Text("目标语言").frame(width: 80, alignment: .leading)
                Picker("", selection: $draft.asr.system.targetLanguage) {
                    Text("中文").tag("zh-Hans-CN")
                    Text("英文").tag("en-US")
                    Text("日语").tag("ja-JP")
                }.labelsHidden().frame(width: 140)
            }
                Text("（翻译功能待实现）").font(.caption2).foregroundStyle(.tertiary)

            if draft.asr.engine == "aliyun" {
                Divider()
                HStack(alignment: .top) {
                    Toggle("语义断句", isOn: $draft.asr.aliyun.semanticPunctuation)
                    Image(systemName: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("开启后使用语义模型自动加标点断句（推荐），关闭后使用 VAD 语音活动检测断句")
                }
                if !draft.asr.aliyun.semanticPunctuation {
                    HStack {
                        Text("停顿时长").frame(width: 80, alignment: .leading)
                        Slider(value: Binding(get: { Double(draft.asr.aliyun.maxSentenceSilence) },
                                               set: { draft.asr.aliyun.maxSentenceSilence = Int($0) }),
                               in: 200...6000, step: 100)
                        Text("\(draft.asr.aliyun.maxSentenceSilence)ms")
                            .font(.caption).frame(width: 50, alignment: .trailing)
                    }
                }
                HStack {
                    Text("VAD 灵敏度").frame(width: 80, alignment: .leading)
                    Slider(value: $draft.asr.aliyun.speechNoiseThreshold, in: -1...1, step: 0.1)
                    Text(String(format: "%+.1f", draft.asr.aliyun.speechNoiseThreshold))
                        .font(.caption).frame(width: 40, alignment: .trailing)
                }

                Divider()
                Toggle("静音自动停止", isOn: $draft.asr.aliyun.autoStopEnabled)
                if draft.asr.aliyun.autoStopEnabled {
                    HStack {
                        Text("静音阈值").frame(width: 80, alignment: .leading)
                        Slider(value: $draft.asr.aliyun.autoStopThreshold, in: 0.005...0.1, step: 0.005)
                        Text(String(format: "%.3f", draft.asr.aliyun.autoStopThreshold))
                            .font(.caption).frame(width: 45, alignment: .trailing)
                    }
                    HStack {
                        Text("超时时间").frame(width: 80, alignment: .leading)
                        Slider(value: $draft.asr.aliyun.autoStopTimeout, in: 1...10, step: 0.5)
                        Text(String(format: "%.1fs", draft.asr.aliyun.autoStopTimeout))
                            .font(.caption).frame(width: 40, alignment: .trailing)
                    }
                }

                Divider()
                labeled("API Key") {
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
                    }.frame(width: 340)
                }
                labeled("Workspace ID") {
                    TextField("ws-...", text: $draft.asr.aliyun.workspaceId)
                        .textFieldStyle(.roundedBorder).frame(width: 340)
                }
                labeled("模型") {
                    TextField("fun-asr-realtime", text: $draft.asr.aliyun.model)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
        }
    }

    // MARK: - AI 润色

    private var llmTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("启用润色", isOn: $draft.llm.enabled)
            if draft.llm.enabled {
                labeled("引擎") {
                    Picker("", selection: $draft.llm.engine) {
                        Text("阿里云（OpenAI 兼容）").tag("openai")
                        Text("Ollama（本地）").tag("ollama")
                        Text("DeepSeek").tag("deepseek")
                        Text("Claude").tag("claude")
                        Text("自定义").tag("custom")
                    }.labelsHidden().frame(width: 260)
                }
                llmFields
                HStack {
                    Text("温度").frame(width: 80, alignment: .leading)
                    Slider(value: llmTemperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", llmTemperature.wrappedValue))
                        .font(.caption).frame(width: 30)
                }
                Toggle("深度思考 (thinking)", isOn: Binding(
                    get: { draft.llm.openai.model.contains("qwq") || draft.llm.openai.model.contains("thinking") },
                    set: { v in
                        draft.llm.openai.model = v ? "qwq-plus" : "qwen-plus"
                    }
                ))
                Divider()
                labeled("系统提示词") {
                    TextField("系统角色描述", text: $draft.llm.prompt.system, axis: .vertical)
                        .textFieldStyle(.roundedBorder).frame(minHeight: 50)
                }
                labeled("用户模板") {
                    TextField("口语内容：{{input}}\n\n改写结果：", text: $draft.llm.prompt.user, axis: .vertical)
                        .textFieldStyle(.roundedBorder).frame(minHeight: 50)
                }
                Text("{{input}} 会被替换为识别文本").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var llmFields: some View {
        switch draft.llm.engine {
        case "ollama":
            labeled("Base URL") {
                TextField("http://localhost:11434", text: $draft.llm.ollama.baseUrl)
                    .textFieldStyle(.roundedBorder).frame(width: 280)
            }
            labeled("模型") {
                TextField("qwen2.5:7b", text: $draft.llm.ollama.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        case "openai":
            labeled("Base URL") {
                TextField("", text: $draft.llm.openai.baseUrl)
                    .textFieldStyle(.roundedBorder).frame(width: 340)
            }
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.openai.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 340)
            }
            labeled("模型") {
                TextField("qwen-plus", text: $draft.llm.openai.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        case "deepseek":
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.deepseek.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 280)
            }
            labeled("模型") {
                TextField("deepseek-v4-flash", text: $draft.llm.deepseek.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        case "custom":
            labeled("Base URL") {
                TextField("https://...", text: $draft.llm.custom.baseUrl)
                    .textFieldStyle(.roundedBorder).frame(width: 340)
            }
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.custom.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 340)
            }
            labeled("模型") {
                TextField("model-name", text: $draft.llm.custom.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        default: EmptyView()
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func persist() {
        ConfigStore.shared.update(draft)
        HotkeyManager.shared.register(hotkeyString: draft.general.hotkey)
        onDone()
    }

    private var llmTemperature: Binding<Double> {
        switch draft.llm.engine {
        case "ollama": return $draft.llm.ollama.temperature
        case "openai": return $draft.llm.openai.temperature
        case "deepseek": return $draft.llm.deepseek.temperature
        case "claude": return $draft.llm.claude.temperature
        case "custom": return $draft.llm.custom.temperature
        default: return .constant(0.7)
        }
    }
}
