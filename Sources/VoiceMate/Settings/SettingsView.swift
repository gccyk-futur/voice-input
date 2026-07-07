import SwiftUI

struct SettingsView: View {
    var onDone: () -> Void = {}

    @State private var draft: AppConfig = .default
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("常规").tag(0)
                Text("语音识别").tag(1)
                Text("AI 润色").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 12)

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
        .frame(width: 520, height: 420)
        .task { draft = ConfigStore.shared.config }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { persist() }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { onDone() }
            }
        }
    }

    // MARK: - 常规

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("全局热键") {
                HotkeyRecorder(hotkeyString: $draft.general.hotkey)
                    .frame(width: 280, height: 24)
            }
            Toggle("登录时启动", isOn: $draft.general.launchAtStartup)

            HStack {
                Text("保留历史").frame(width: 70, alignment: .leading)
                Picker("", selection: $draft.general.maxHistoryCount) {
                    Text("20 条").tag(20)
                    Text("50 条").tag(50)
                    Text("100 条").tag(100)
                    Text("200 条").tag(200)
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }

    // MARK: - 语音识别

    private var asrTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("引擎") {
                Picker("", selection: $draft.asr.engine) {
                    Text("系统听写（稳定，不抢焦点）").tag("system")
                    Text("阿里云 Fun-ASR（在线，高精度带标点）").tag("aliyun")
                }
                .labelsHidden()
                .frame(width: 300)
            }
            labeled("语言") {
                TextField("zh-CN", text: $draft.asr.system.language)
                    .textFieldStyle(.roundedBorder).frame(width: 160)
            }
            if draft.asr.engine == "aliyun" {
                Divider()
                labeled("API Key") {
                    SecureField("sk-...", text: $draft.asr.aliyun.apiKey)
                        .textFieldStyle(.roundedBorder).frame(width: 320)
                }
                labeled("Workspace ID") {
                    TextField("ws-...", text: $draft.asr.aliyun.workspaceId)
                        .textFieldStyle(.roundedBorder).frame(width: 320)
                }
                labeled("模型") {
                    TextField("fun-asr-realtime", text: $draft.asr.aliyun.model)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
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
                    }
                    .labelsHidden().frame(width: 260)
                }
                llmFields
                Divider()
                Text("系统提示词").font(.caption).foregroundStyle(.secondary)
                TextField("system", text: $draft.llm.prompt.system, axis: .vertical)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                Text("用户模板（支持 {{input}}）").font(.caption).foregroundStyle(.secondary)
                TextField("user", text: $draft.llm.prompt.user, axis: .vertical)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 70)
            }
        }
    }

    @ViewBuilder
    private var llmFields: some View {
        switch draft.llm.engine {
        case "ollama":
            labeled("Base URL") {
                TextField("http://localhost:11434", text: $draft.llm.ollama.baseUrl)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            labeled("模型") {
                TextField("qwen2.5:7b", text: $draft.llm.ollama.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        case "openai":
            labeled("Base URL") {
                TextField("", text: $draft.llm.openai.baseUrl)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
            }
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.openai.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
            }
            labeled("模型") {
                TextField("gpt-4o-mini", text: $draft.llm.openai.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        case "deepseek":
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.deepseek.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            labeled("模型") {
                TextField("deepseek-v4-flash", text: $draft.llm.deepseek.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        case "custom":
            labeled("Base URL") {
                TextField("https://...", text: $draft.llm.custom.baseUrl)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
            }
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.custom.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
            }
            labeled("模型") {
                TextField("model-name", text: $draft.llm.custom.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        default: EmptyView()
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func persist() {
        ConfigStore.shared.update(draft)
        HotkeyManager.shared.register(hotkeyString: draft.general.hotkey)
        onDone()
    }
}
