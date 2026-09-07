import SwiftUI
import AppKit

/// 状态栏弹出面板：卡片式控制区（引擎 + AI 服务）+ 主操作区（速插/历史/设置）。
/// 职责边界：本面板只管「配置与入口」。会话状态（聆听/转写/润色）由光标旁的
/// 浮层面板承担，此处不再重复显示——录音中用户不会、也不需要点开状态栏。
/// 使用 .menuBarExtraStyle(.window) 获得完整的 SwiftUI 布局自由度。
struct StatusBarMenuView: View {
    @AppStorage("voicekit.ui.textScale") private var textScaleRawValue = VoiceKitTextScale.system.rawValue
    @State private var config = ConfigStore.shared.config
    @State private var coordinator = AppCoordinator.shared
    @State private var toastMessage: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var hoveringVersion = false
    @State private var hoveringQuit = false

    private var textScale: VoiceKitTextScale {
        VoiceKitTextScale.restored(from: textScaleRawValue)
    }

    private var typography: VoiceKitTypography {
        VoiceKitTypography(scale: textScale)
    }

    private var popoverMinWidth: CGFloat {
        260 * textScale.multiplier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.md) {
            // ── 标题栏：纯品牌 ──
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("VoiceKit").font(typography.sectionTitle)
                Spacer()
            }
            .padding(.horizontal, 6)

            // ── 控制卡：语音引擎 + AI 服务 ──
            VStack(alignment: .leading, spacing: VoiceKitDesign.Spacing.md) {
                engineBlock
                Divider()
                llmBlock
            }
            .voiceKitPopoverCard()

            // ── Toast 提示 ──
            if let msg = toastMessage {
                Text(msg)
                    .font(typography.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── 主操作区：图标+文字纵向三键，语义自解释 ──
            HStack(spacing: 2) {
                MainActionButton(title: VoiceKitLocalization.string("速插"),
                                 systemImage: "square.and.arrow.down.on.square") {
                    QuickInsertPanelController.shared.show()
                    dismissMenuBarExtra()
                }
                MainActionButton(title: VoiceKitLocalization.string("历史记录"),
                                 systemImage: "clock") {
                    HistoryWindowController.shared.show()
                    dismissMenuBarExtra()
                }
                MainActionButton(title: VoiceKitLocalization.string("设置…"),
                                 systemImage: "gearshape") {
                    SettingsWindowController.shared.show()
                    dismissMenuBarExtra()
                }
            }

            // ── 底栏：版本号（官网入口）+ 退出。低频信息降级至此 ──
            HStack(spacing: 6) {
                // 版本号即官网入口：点击打开独立站产品主页
                Button {
                    NSWorkspace.shared.open(Self.homepageURL)
                } label: {
                    Text(VoiceKitDesign.versionLine)
                        .font(typography.metadata)
                        .foregroundStyle(hoveringVersion ? .secondary : .tertiary)
                        .underline(hoveringVersion)
                }
                .buttonStyle(.plain)
                .voiceKitToolTip("ckai.me/voice-kit")
                .onHover { hovering in
                    hoveringVersion = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Spacer()

                // 退出与主操作分离：破坏性操作视觉降级，悬停才显红
                Button {
                    // 退出按钮直接 terminate，不跑 dismiss 避免潜在的窗口释放冲突
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 3) {
                        Text(VoiceKitLocalization.string("退出"))
                        Image(systemName: "power")
                    }
                    .font(typography.metadata)
                    .foregroundStyle(hoveringQuit ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .voiceKitToolTip(VoiceKitLocalization.string("退出"))
                .accessibilityLabel(VoiceKitLocalization.string("退出"))
                .onHover { hoveringQuit = $0 }
                .animation(.easeOut(duration: 0.12), value: hoveringQuit)
            }
            .padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: popoverMinWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .voiceKitTextScale(textScale)
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
        // 版式与 AI 服务行一致：左侧分组小标题、右侧紧凑下拉，不再用全宽选择框。
        HStack(spacing: 8) {
            sectionTitle("语音引擎")

            // 连接状态灯只在「有问题」时出现，正常状态一律不显示：
            // 用户并不区分常驻连接与会话制连接，一个只对某个引擎亮起的绿灯
            // 只会让人疑惑；而永远亮着的绿灯也不传递任何可行动的信息。
            // 阿里云是预建连，断开意味着按下热键会失败，值得提前告知 → 显示红点；
            // 讯飞/Deepgram 录音时才建连，空闲无连接属正常 → 不显示。
            if coordinator.asrEngineChoice == "aliyun", !coordinator.wsConnected {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel(VoiceKitLocalization.string("连接状态"))
                    .accessibilityValue(coordinator.wsStatusText)
                    .voiceKitToolTip(coordinator.wsStatusText)
            }

            Spacer(minLength: 4)

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
                HStack(spacing: 3) {
                    Text(Self.engineOptions.first { $0.id == coordinator.asrEngineChoice }?.title
                         ?? VoiceKitLocalization.string("系统听写"))
                        .font(typography.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(typography.metadata)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(minHeight: 28)
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
                .labelsHidden()
            }
            .frame(minHeight: 28)

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
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(VoiceKitLocalization.string("选择提示词"))
                        .voiceKitToolTip(VoiceKitLocalization.string("选择提示词"))
                    }
                }
            }
        }
    }

    // MARK: - 辅助

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

    /// 官网主页（独立站产品页）
    private static let homepageURL = URL(string: "https://ckai.me/voice-kit")!

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
}

/// 主操作按钮：图标在上、文字在下的纵向布局。
/// 纯图标无人能懂（尤其「速插」），文字标签让语义自解释，tooltip 降级为补充。
private struct MainActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.voiceKitTextScale) private var textScale
    @State private var hovering = false

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15 * textScale.multiplier))
                Text(title)
                    .font(typography.secondary)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: VoiceKitDesign.Radius.card, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .voiceKitToolTip(title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    /// 状态栏面板专用卡片：圆角 10 与面板系统圆角咬合；去掉描边——0.5px 半透明
    /// 描边在毛玻璃上若隐若现，视觉上显脏，只靠填充差分区即可。
    /// 共享的 voiceKitCard 仍被历史窗口等使用，不在此改动。
    func voiceKitPopoverCard() -> some View {
        padding(10)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}
