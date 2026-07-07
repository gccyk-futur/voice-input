import SwiftUI

/// 设置界面：常规 / 语音识别 / 润色（含 Prompt）。采用草稿模式，保存时回写 ConfigStore。
struct SettingsView: View {
    var onDone: () -> Void = {}

    @State private var draft: AppConfig = .default

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                asrSection
                llmSection
            }
            .padding(20)
        }
        .frame(width: 520)
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

    // MARK: - 区块

    private var generalSection: some View {
        GroupBox("常规") {
            VStack(alignment: .leading, spacing: 10) {
                labeled("全局热键") {
                    HotkeyRecorder(hotkeyString: $draft.general.hotkey)
                        .frame(width: 280, height: 24)
                }
                Toggle("登录时启动", isOn: $draft.general.launchAtStartup)
            }
            .padding(8)
        }
    }

    private var asrSection: some View {
        GroupBox("语音识别") {
            VStack(alignment: .leading, spacing: 10) {
                labeled("引擎") {
                    Picker("", selection: $draft.asr.engine) {
                        Text("系统听写（稳定，不抢焦点）").tag("system")
                        Text("连续听写（更流畅，需前台）").tag("dictation")
                        Text("Whisper（本地，待实现）").tag("whisper")
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
                labeled("语言") {
                    TextField("zh-CN", text: $draft.asr.system.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }
            .padding(8)
        }
    }

    private var llmSection: some View {
        GroupBox("AI 润色（可选）") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用润色", isOn: $draft.llm.enabled)
                if draft.llm.enabled {
                    labeled("引擎") {
                        Picker("", selection: $draft.llm.engine) {
                        Text("Ollama（本地）").tag("ollama")
                        Text("OpenAI").tag("openai")
                        Text("DeepSeek").tag("deepseek")
                        Text("Claude").tag("claude")
                        Text("自定义").tag("custom")
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    llmFields
                    Divider()
                    Text("系统提示词").font(.caption).foregroundStyle(.secondary)
                    TextField("system", text: $draft.llm.prompt.system, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                    Text("用户模板（支持 {{input}}）").font(.caption).foregroundStyle(.secondary)
                    TextField("user", text: $draft.llm.prompt.user, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 90)
                }
            }
            .padding(8)
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
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.openai.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
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
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            labeled("API Key") {
                SecureField("sk-...", text: $draft.llm.custom.apiKey)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            labeled("模型") {
                TextField("model-name", text: $draft.llm.custom.model)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - 辅助

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func persist() {
        ConfigStore.shared.update(draft)
        // 保存后立即重新注册热键，使修改即时生效（无需重启）。
        HotkeyManager.shared.register(hotkeyString: draft.general.hotkey)
        onDone()
    }
}
