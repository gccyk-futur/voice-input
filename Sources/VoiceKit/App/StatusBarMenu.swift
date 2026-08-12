import SwiftUI
import AppKit

/// 状态栏弹出面板：Surge 风格，支持引擎切换、润色开关、历史记录行内复制。
/// 使用 .menuBarExtraStyle(.window) 获得完整的 SwiftUI 布局自由度。
struct StatusBarMenuView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var config = ConfigStore.shared.config
    @State private var historyItems: [HistoryItem] = []
    @State private var coordinator = AppCoordinator.shared
    @State private var toastMessage: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var hoveredItemID: String?

    private var textScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: textScale)
    }

    private var popoverMinWidth: CGFloat {
        320 * textScale.multiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 标题栏 ──
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("VoiceKit").font(typography.sectionTitle)
                Spacer()
                Text("\(channelName) · v\(versionString)")
                    .font(typography.metadata).foregroundStyle(.secondary)
                if coordinator.sessionState != .idle {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 10)

            // ── 引擎切换 ──
            engineSection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider().padding(.horizontal, 10)

            // ── AI 服务 ──
            llmSection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider().padding(.horizontal, 10)

            // ── 历史记录 ──
            historySection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            // ── Toast 提示 ──
            if let msg = toastMessage {
                Text(msg)
                    .font(typography.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── 底部操作区 ──
            Divider().padding(.horizontal, 10)
            HStack(spacing: 0) {
                bottomButton("历史记录", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    HistoryWindowController.shared.show()
                }
                Divider().frame(height: 20)
                bottomButton("设置…", systemImage: "gearshape") {
                    SettingsWindowController.shared.show()
                }
                Divider().frame(height: 20)
                bottomButton("退出", systemImage: "xmark") {
                    // bottomButton 内部会处理 terminate
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: popoverMinWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .voiceKitTextScale(textScale)
        .task { reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: ConfigStore.didChange)) { _ in
            config = ConfigStore.shared.config
        }
    }

    // MARK: - 引擎

    private var engineSection: some View {
        // 使用 coordinator 的实时状态（由配置变更通知和连接回调驱动），
        // 不再依赖本地 config 快照——首次在设置中填好后无需重启即可切换。
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("语音引擎")
                    .font(typography.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)

                // 连接状态灯对全部云端引擎展示。语义差异：
                // - 阿里云是常驻连接（预建连），断开即异常，红色警示；
                // - 讯飞/Deepgram 是会话制连接，只在录音期间存在，
                //   空闲时灰色「未连接」属正常，不作红色警示。
                if coordinator.asrEngineChoice != "system" {
                    let persistent = coordinator.asrEngineChoice == "aliyun"
                    let connected = coordinator.wsConnected
                    Circle()
                        .fill(connected ? Color.green : (persistent ? Color.red : Color.secondary))
                        .frame(width: 5, height: 5)
                    Text(connected
                         ? VoiceKitLocalization.string("已连接")
                         : VoiceKitLocalization.string("未连接"))
                        .font(typography.metadata)
                        .foregroundStyle(connected
                                         ? VoiceKitSemanticColor.success
                                         : (persistent ? VoiceKitSemanticColor.failure : .secondary))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel(VoiceKitLocalization.string("连接状态"))
                        .accessibilityValue(coordinator.wsStatusText)
                        .help(coordinator.wsStatusText)
                }
            }

            // 用 Menu + 自绘全宽 label 替代 .menu 样式的 Picker：
            // macOS 26 上 Picker(.menu) 按钮只吃内容宽度、不响应 maxWidth 拉伸，
            // 文字居中显得两侧空荡；Menu 的 label 可以完全控制布局。
            Menu {
                ForEach(Self.engineOptions, id: \.id) { option in
                    Button {
                        selectEngine(option.id)
                    } label: {
                        let selected = coordinator.asrEngineChoice == option.id
                        if selected {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.engineOptions.first { $0.id == coordinator.asrEngineChoice }?.title
                         ?? VoiceKitLocalization.string("系统听写"))
                        .font(typography.body)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(typography.metadata)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
        }
    }

    /// 引擎可选项（与设置页列表口径一致）
    private static let engineOptions: [(id: String, title: String)] = [
        ("system", VoiceKitLocalization.string("系统听写")),
        ("aliyun", VoiceKitLocalization.string("阿里云 Fun-ASR")),
        ("xunfei", VoiceKitLocalization.string("讯飞听写")),
        ("deepgram", "Deepgram")
    ]

    private func selectEngine(_ newValue: String) {
        guard newValue != coordinator.asrEngineChoice else { return }
        var cfg = ConfigStore.shared.config
        cfg.asr.engine = newValue
        config = cfg
        ConfigStore.shared.update(cfg)
        coordinator.invalidateASREngine()
        // 切到阿里云后主动预建连，确保状态灯正常
        if newValue == "aliyun" {
            Task { await coordinator.prewarmAliyunEngine() }
        } else if !Self.isEngineConfigured(newValue, asr: cfg.asr) {
            showToast("所选引擎未配置凭据，录音时将回退到系统听写")
        }
    }

    // MARK: - AI 服务

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AI 服务").font(typography.sectionTitle)
                Spacer(minLength: 4)

                // 开关开启后才出现：模型/提示词紧凑下拉，收进标题行
                if config.llm.enabled {
                    if !config.llm.models.isEmpty {
                        Picker("", selection: Binding(
                            get: { config.llm.selectedModelID },
                            set: { v in
                                var cfg = config
                                cfg.llm.selectedModelID = v
                                config = cfg
                                ConfigStore.shared.update(cfg)
                            }
                        )) {
                            ForEach(config.llm.models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 120 * textScale.multiplier)
                        .accessibilityLabel(VoiceKitLocalization.string("选择润色模型"))
                        .help(VoiceKitLocalization.string("选择润色模型"))
                    }

                    if !config.llm.prompts.isEmpty {
                        Picker("", selection: Binding(
                            get: { config.llm.selectedPromptID },
                            set: { v in
                                var cfg = config
                                cfg.llm.selectedPromptID = v
                                config = cfg
                                ConfigStore.shared.update(cfg)
                            }
                        )) {
                            Text("默认").tag("")
                            ForEach(config.llm.prompts) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 100 * textScale.multiplier)
                        .accessibilityLabel(VoiceKitLocalization.string("选择提示词"))
                        .help(VoiceKitLocalization.string("选择提示词"))
                    }
                }

                Toggle("", isOn: Binding(
                    get: { config.llm.enabled },
                    set: { v in
                        guard v else {
                            // 关闭 → 直接允许
                            var cfg = config
                            cfg.llm.enabled = false
                            config = cfg
                            ConfigStore.shared.update(cfg)
                            return
                        }
                        // 开启 → 检查配置是否完整
                        var cfg = config
                        guard let model = cfg.llm.selectedModel else {
                            showToast("请先在设置中添加模型")
                            return
                        }
                        if model.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty ||
                           model.model.trimmingCharacters(in: .whitespaces).isEmpty {
                            showToast("请先在设置中完善模型信息")
                            return
                        }
                        // 真正测试联通性（异步）
                        let engine: any LLMEngine = AppCoordinator.buildLLMEngine(from: model, temperature: cfg.llm.temperature)
                        Task {
                            let ok = await engine.checkConnectivity()
                            if ok {
                                cfg.llm.enabled = true
                                config = cfg
                                ConfigStore.shared.update(cfg)
                            } else {
                                showToast("无法连接到 LLM 服务，请在设置中检查配置")
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    // MARK: - 历史记录（内联展开）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：左侧分组标题，右侧保留数量
            HStack {
                Text("历史记录")
                    .font(typography.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer()
                if !historyItems.isEmpty {
                    Text(VoiceKitLocalization.format("已记录 %lld/%lld 条", historyItems.count, config.general.maxHistoryCount))
                        .font(typography.metadata).foregroundStyle(.secondary)
                }
            }
            if historyItems.isEmpty {
                Text("暂无记录")
                    .font(typography.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(historyItems.prefix(5).enumerated()), id: \.element.id) { idx, item in
                    Button(action: { copyItem(item) }) {
                        HStack(spacing: 4) {
                            Text("\(idx + 1).")
                                .font(typography.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .leading)
                            Text(item.llmResult ?? item.asrResult)
                                .font(typography.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            // 悬停时露出复制图标，让「点击复制」可被发现
                            if hoveredItemID == item.id {
                                Image(systemName: "doc.on.doc")
                                    .font(typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoveredItemID == item.id ? Color.primary.opacity(0.08) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(VoiceKitLocalization.string("复制历史记录"))
                    .help(VoiceKitLocalization.string("点击复制到剪贴板"))
                    .onHover { hovering in
                        hoveredItemID = hovering ? item.id : nil
                    }
                }
            }
        }
    }

    private func copyItem(_ item: HistoryItem) {
        let text = item.llmResult ?? item.asrResult
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("已复制")
    }

    // MARK: - 底部操作

    private func bottomButton(_ titleKey: String, systemImage: String, action: @escaping () -> Void) -> some View {
        let title = VoiceKitLocalization.string(titleKey)
        return Button(action: {
            // 退出按钮直接 terminate，不跑 dismiss 避免潜在的窗口释放冲突
            if titleKey == "退出" {
                NSApp.terminate(nil)
                return
            }
            action()
            dismissMenuBarExtra()
        }) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(typography.callout)
                Text(title).font(typography.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// 在面板内显示临时提示，3 秒后自动消失。
    private func showToast(_ messageKey: String) {
        toastWork?.cancel()
        toastMessage = VoiceKitLocalization.string(messageKey)
        let work = DispatchWorkItem { self.toastMessage = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// 关闭弹出面板（NSPopover，由 AppDelegate 管理）
    private func dismissMenuBarExtra() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.dismissPopover()
        }
    }

    // MARK: - 辅助

    /// 与设置页必填校验口径一致：判断引擎凭据是否已填写，
    /// 用于状态栏切换时提示「未配置将回退系统听写」。
    private static func isEngineConfigured(_ engine: String, asr: ASRConfig) -> Bool {
        switch engine {
        case "aliyun":
            return !asr.aliyun.apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !asr.aliyun.workspaceId.trimmingCharacters(in: .whitespaces).isEmpty
        case "xunfei":
            return !asr.xunfei.appId.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !asr.xunfei.apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !asr.xunfei.apiSecret.trimmingCharacters(in: .whitespaces).isEmpty
        case "deepgram":
            return !asr.deepgram.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return true
        }
    }

    private var statusColor: Color {
        switch coordinator.sessionState {
        case .recording: return VoiceKitSemanticColor.failure
        case .transcribing, .polishing: return VoiceKitSemanticColor.warning
        case .ready: return VoiceKitSemanticColor.success
        default: return .gray
        }
    }

    private func reloadHistory() {
        historyItems = HistoryStore.shared.items
    }

    // MARK: - 版本 / 渠道

    /// 当前分发渠道：App Store 版（沙盒）或官网版。
    private var channelName: String {
#if APP_STORE
        "App Store"
#else
        VoiceKitLocalization.string("官网版")
#endif
    }

    /// 版本号（如 1.0.0 · 30）。
    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
