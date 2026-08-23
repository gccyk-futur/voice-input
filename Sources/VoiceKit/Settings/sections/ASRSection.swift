import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - 语音识别（ASR）设置（自 SettingsView.swift 机械拆出，逻辑未改动）

extension SettingsView {
    var asrTab: some View {
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
    func engineRow(_ engineID: String, title: String, desc: String) -> some View {
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
    func connTestRow(engineID: String, enabled: Bool,
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
    func secretField(_ label: String, text: Binding<String>) -> some View {
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

}
