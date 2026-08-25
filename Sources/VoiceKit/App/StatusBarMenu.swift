import SwiftUI
import AppKit

/// 状态栏弹出面板：卡片式分区（引擎+AI 服务 / 历史记录），支持引擎切换、
/// 润色开关、历史记录行内复制。使用 .menuBarExtraStyle(.window) 获得完整的 SwiftUI 布局自由度。
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
        340 * textScale.multiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.md) {
            // ── 标题栏：品牌 + 渠道版本（与浮层面板同一心智）──
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("VoiceKit").font(typography.sectionTitle)
                Spacer()
                if coordinator.sessionState != .idle {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                Text(VoiceKitDesign.versionLine)
                    .font(typography.metadata).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)

            // ── 控制卡：语音引擎 + AI 服务 ──
            VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.md) {
                engineBlock
                Divider()
                llmBlock
            }
            .voiceKitCard()

            // ── 历史卡 ──
            historyCard

            // ── Toast 提示 ──
            if let msg = toastMessage {
                Text(msg)
                    .font(typography.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── 底部操作区 ──
            HStack(spacing: 2) {
                BottomButton(title: VoiceKitLocalization.string("速插"),
                             systemImage: "square.and.arrow.down.on.square") {
                    QuickInsertPanelController.shared.show()
                    dismissMenuBarExtra()
                }
                BottomButton(title: VoiceKitLocalization.string("历史记录"),
                             systemImage: "clock") {
                    HistoryWindowController.shared.show()
                    dismissMenuBarExtra()
                }
                BottomButton(title: VoiceKitLocalization.string("设置…"),
                             systemImage: "gearshape") {
                    SettingsWindowController.shared.show()
                    dismissMenuBarExtra()
                }
                BottomButton(title: VoiceKitLocalization.string("退出"),
                             systemImage: "xmark") {
                    // 退出按钮直接 terminate，不跑 dismiss 避免潜在的窗口释放冲突
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(10)
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

    /// 卡片内的分组小标题
    private func sectionTitle(_ key: String) -> some View {
        Text(VoiceKitLocalization.string(key))
            .font(typography.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var engineBlock: some View {
        // 使用 coordinator 的实时状态（由配置变更通知和连接回调驱动），
        // 不再依赖本地 config 快照——首次在设置中填好后无需重启即可切换。
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.sm) {
            HStack(spacing: 6) {
                sectionTitle("语音引擎")
                Spacer(minLength: 4)

                // 连接状态灯只在「有问题」时出现，正常状态一律不显示：
                // 用户并不区分常驻连接与会话制连接，一个只对某个引擎亮起的绿灯
                // 只会让人疑惑；而永远亮着的绿灯也不传递任何可行动的信息。
                // 阿里云是预建连，断开意味着按下热键会失败，值得提前告知 → 显示红点；
                // 讯飞/Deepgram 录音时才建连，空闲无连接属正常 → 不显示。
                if coordinator.asrEngineChoice == "aliyun", !coordinator.wsConnected {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                    Text(VoiceKitLocalization.string("未连接"))
                        .font(typography.metadata)
                        .foregroundStyle(VoiceKitSemanticColor.failure)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel(VoiceKitLocalization.string("连接状态"))
                        .accessibilityValue(coordinator.wsStatusText)
                        .voiceKitToolTip(coordinator.wsStatusText)
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
                    RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
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

    private var llmBlock: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.sm) {
            HStack(spacing: 8) {
                sectionTitle("AI 服务")
                Spacer(minLength: 4)

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
                .controlSize(.small)
                .labelsHidden()
            }

            // 开关开启后才出现：模型/提示词紧凑下拉
            if config.llm.enabled {
                HStack(spacing: 8) {
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
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(VoiceKitLocalization.string("选择润色模型"))
                        .voiceKitToolTip(VoiceKitLocalization.string("选择润色模型"))
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
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(VoiceKitLocalization.string("选择提示词"))
                        .voiceKitToolTip(VoiceKitLocalization.string("选择提示词"))
                    }
                }
            }
        }
    }

    // MARK: - 历史记录（内联展开）

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.xs) {
            HStack {
                sectionTitle("历史记录")
                Spacer()
                if !historyItems.isEmpty {
                    Text(VoiceKitLocalization.format("已记录 %lld/%lld 条", historyItems.count, config.general.maxHistoryCount))
                        .font(typography.metadata).foregroundStyle(.tertiary)
                }
            }
            if historyItems.isEmpty {
                Text("暂无记录")
                    .font(typography.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ForEach(historyItems.prefix(5)) { item in
                    Button(action: { copyItem(item) }) {
                        HStack(spacing: 6) {
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
                                .fill(hoveredItemID == item.id ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(VoiceKitLocalization.string("复制历史记录"))
                    .voiceKitToolTip(VoiceKitLocalization.string("点击复制到剪贴板"))
                    .onHover { hovering in
                        hoveredItemID = hovering ? item.id : nil
                    }
                }
            }
        }
        .voiceKitCard()
    }

    private func copyItem(_ item: HistoryItem) {
        let text = item.llmResult ?? item.asrResult
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("已复制")
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
}

/// 底部操作按钮：图标 + 文字，悬浮底板反馈。
private struct BottomButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.voiceKitTextScale) private var textScale
    @State private var hovering = false

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(typography.callout)
                Text(title).font(typography.callout)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.control, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
