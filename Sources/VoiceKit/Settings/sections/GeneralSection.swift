import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - 常规设置（自 SettingsView.swift 机械拆出，逻辑未改动）

extension SettingsView {
    func applyLanguagePreference(_ raw: String) {
        if raw.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([raw], forKey: "AppleLanguages")
        }
        languageNeedsRestart = (raw != launchedLanguageRawValue)
    }

    // MARK: - 常规

    var generalTab: some View {
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
                Picker("剪贴板保留时长", selection: $draft.general.clipboardRetentionSeconds) {
                    Text("永不还原").tag(0.0)
                    Text("15 秒").tag(15.0)
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                }
            } footer: {
                Text("需要手动按 ⌘V 粘贴时，识别文字会在剪贴板中保留此时长；超时后将还原为你原本的剪贴板内容。选「永不还原」则等同普通复制。")
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

    var startSoundEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.general.sound.start },
            set: { draft.general.sound.startEnabled = $0 }
        )
    }

    var stopSoundEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.general.sound.stop },
            set: { draft.general.sound.stopEnabled = $0 }
        )
    }

    /// 启用 AI 润色前校验：无可用模型或模型信息不完整时阻止开启并给出引导。
    var llmEnabledBinding: Binding<Bool> {
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

}
