import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

struct SettingsView: View {
    /// 窗口控制器桥：同步未保存变更状态，接收红叉关闭的确认请求
    var bridge: SettingsWindowBridge? = nil
    var onDone: () -> Void = {}
    var onTabChange: (Int) -> Void = { _ in }

    @State var draft: AppConfig = ConfigStore.shared.config
    /// 打开设置时的原始配置，用于判断是否有未保存变更
    @State var originalConfig: AppConfig = ConfigStore.shared.config
    @AppStorage("voicekit.settings.selectedPane") var selectedPaneRawValue = SettingsPane.general.rawValue
    @AppStorage("voicekit.ui.textScale") var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @AppStorage("voicekit.ui.appearance") var appearanceRawValue = VoiceKitAppearance.system.rawValue
    /// 界面语言偏好：空字符串 = 跟随系统；否则为 lproj 目录名（zh-Hans/en/…）。
    /// 与外观/文字大小一样是即时生效的 UI 偏好，但语言包在下次启动才加载，
    /// 所以改动后提示重启（NSLocalizedString 由系统按 AppleLanguages 解析）。
    @AppStorage("voicekit.ui.language") var languageRawValue = ""
    /// 本次启动时的语言偏好，用于判断改动后是否需要提示重启
    let launchedLanguageRawValue = UserDefaults.standard.string(forKey: "voicekit.ui.language") ?? ""
    @State var languageNeedsRestart = false
    @State var selectedPane = SettingsPane.general
    @State var showAPIKey = false
    @State var permissionRefreshID = UUID()
    /// 本地数据各文件的大小（进入隐私分页时刷新）。
    @State var localDataSizes: [String: UInt64] = [:]
    @State var postEventRequestAttempted = false
    @State var postEventRestartDismissed = false
    @State var restartRequested = false

    // 保存校验
    @State var showValidationAlert = false
    @State var validationMessage = ""

    // 启用 AI 润色前的模型校验
    @State var showLLMEnableGuardAlert = false
    @State var llmEnableGuardMessage = ""

    // 提示词预览
    @State var showPromptPreview = false

    // LLM 润色测试
    @State var showLLMTest = false

    // 模型管理（内联列表）
    @State var editingModel: LLMModelDef?
    @State var showModelDeleteConfirm = false
    @State var modelToDelete: LLMModelDef?
    @State var modelTestResults: [String: ModelTestResult] = [:]
    @State var isTestingModels = false
    @State var testedModelCount = 0

    // 提示词
    @State var showPromptDeleteConfirm = false
    @State var promptToDelete: LLMPromptPreset?
    @State var editingPrompt: PromptEditing?

    // 恢复默认
    @State var showResetConfirm = false

    // ASR 连接测试
    @State var connTestRunning: String?
    @State var connTestResults: [String: ASRConnTestResult] = [:]

    @State var showDiscardAlert = false

    // 本地数据「清空」确认（不可逆操作）
    @State var pendingClearTitle = ""
    @State var pendingClearAction: (() -> Void)?

    // 使用统计（StatsSection）
    @State var statsSummary: UsageStatsSummary.Summary = .init()
    @State var statsLoaded = false

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
        .confirmationDialog(
            pendingClearTitle,
            isPresented: Binding(
                get: { pendingClearAction != nil },
                set: { if !$0 { pendingClearAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                pendingClearAction?()
                pendingClearAction = nil
            }
            Button("取消", role: .cancel) { pendingClearAction = nil }
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
    var sidebarColumn: some View {
        List(SettingsPane.allCases, selection: $selectedPane) { pane in
            // 字号打在行内容上：.sidebar 样式忽略 List 级 .font（字体缩放不生效的根因）
            Label(pane.title, systemImage: pane.systemImage)
                .font(typography.body)
                .tag(pane)
                .padding(.leading, pane.isSubpane ? 16 : 0)
        }
        .listStyle(.sidebar)
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

    var detailColumn: some View {
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

    var selectedTextScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    var typography: VoiceKitTypography {
        VoiceKitTypography(scale: selectedTextScale)
    }

    @ViewBuilder
    var paneContent: some View {
        switch selectedPane {
        case .general: generalTab
        case .input: asrTab
        case .services: aiServiceOverviewTab
        case .models: modelTab
        case .prompts: promptTab
        case .permissions: permissionTab
        case .privacy: privacyTab
        case .stats: statsTab
        case .history: historySettingsTab
        case .about: aboutTab
        }
    }

    // MARK: - 面板标题

    /// 每个设置面板的标题与一句话说明，切换侧边栏时同步更新，
    /// 让用户始终知道自己处于哪个设置域（HIG：清晰的位置反馈）。
    @ViewBuilder
    var paneHeader: some View {
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

    static let systemSounds: [(String, String)] = [
        ("Basso", "Basso"), ("Blow", "Blow"), ("Bottle", "Bottle"),
        ("Frog", "Frog"), ("Funk", "Funk"), ("Glass", "Glass"),
        ("Hero", "Hero"), ("Morse", "Morse"), ("Ping", "Ping"),
        ("Pop", "Pop"), ("Purr", "Purr"), ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"), ("Tink", "Tink"),
    ]

    // MARK: - 界面语言

    /// 可选界面语言：code 为 lproj 目录名（即 AppleLanguages 取值），
    /// name 用各语言自称（这部分不需要本地化）。
    static let availableLanguages: [(code: String, name: String)] = [
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

    func dismissRestartRow() {
        if case .recommended(.postEvent) = restartState {
            postEventRestartDismissed = true
        } else {
            restartRequested = false
        }
    }

    func restartApplication() {
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

    func closeSettings() {
        if hasChanges {
            showDiscardAlert = true
        } else {
            onDone()
        }
    }

    /// 当前 draft 与打开时的原始配置是否有差异
    var hasChanges: Bool {
        draft != originalConfig
    }

    // MARK: - 保存

    func save() {
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
        HotkeyManager.shared.registerSecondary(hotkeyString: draft.general.quickInsertHotkey)
        originalConfig = draft
        DispatchQueue.main.async {
            self.onDone()
        }
    }

    // MARK: - 关于


}

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
