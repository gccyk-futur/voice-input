import SwiftUI
import AppKit

/// 状态栏弹出面板：Surge 风格，支持引擎切换、润色开关、历史记录行内复制。
/// 使用 .menuBarExtraStyle(.window) 获得完整的 SwiftUI 布局自由度。
struct StatusBarMenuView: View {
    @State private var config = ConfigStore.shared.config
    @State private var historyItems: [HistoryItem] = []
    @State private var coordinator = AppCoordinator.shared
    @State private var toastMessage: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var hoveredItemID: String?

    private let popoverMinWidth: CGFloat = 260
    private let popoverMaxHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 标题栏 ──
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("VoiceMate").font(.headline)
                Spacer()
                if coordinator.sessionState != .idle {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 10)

            // ── 引擎切换 ──
            engineSection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Divider().padding(.horizontal, 10)

            // ── AI 润色开关 ──
            llmToggleSection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Divider().padding(.horizontal, 10)

            // ── 历史记录 ──
            historySection
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            // ── Toast 提示 ──
            if let msg = toastMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

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
        .frame(width: popoverMinWidth)
        .frame(maxHeight: popoverMaxHeight)
        .task { reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange)) { _ in reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: ConfigStore.didChange)) { _ in
            config = ConfigStore.shared.config
        }
    }

    // MARK: - 引擎

    private var engineSection: some View {
        let aliyunConfigured = !config.asr.aliyun.apiKey.isEmpty && !config.asr.aliyun.workspaceId.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("语音引擎").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            // 未配置阿里云 → 只显示「系统听写」，提供配置入口
            // 已配置阿里云 → 显示双引擎 Picker，可选切换
            if aliyunConfigured {
                Picker("", selection: Binding(
                    get: { config.asr.engine },
                    set: { newValue in
                        var cfg = config
                        cfg.asr.engine = newValue
                        config = cfg
                        ConfigStore.shared.update(cfg)
                        coordinator.invalidateASREngine()
                        // 切到阿里云后主动预建连，确保状态灯正常
                        if newValue == "aliyun" {
                            Task { await coordinator.prewarmAliyunEngine() }
                        }
                    }
                )) {
                    Text("系统听写").tag("system")
                    Text("阿里云 Fun-ASR").tag("aliyun")
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if config.asr.engine == "aliyun" {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(coordinator.wsConnected ? Color.green : Color.red)
                            .frame(width: 5, height: 5)
                        Text(coordinator.wsConnected ? "已连接" : "未连接")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                // 仅显示系统听写 + 配置阿里云的入口
                HStack {
                    Text("系统听写").font(.body)
                    Spacer()
                    Button("配置阿里云引擎 →") {
                        SettingsWindowController.shared.show()
                        dismissMenuBarExtra()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - AI 润色

    private var llmToggleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 润色").font(.body)
                    HStack(spacing: 4) {
                        Text(llmEngineLabel)
                            .font(.caption2)
                        Text(config.llm.enabled ? "已开启" : "已关闭")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { config.llm.enabled },
                    set: { v in
                        guard v else {
                            // 关闭润色 → 直接允许
                            var cfg = config
                            cfg.llm.enabled = false
                            config = cfg
                            ConfigStore.shared.update(cfg)
                            return
                        }
                        // 开启润色 → 检查配置是否完整
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

    private var llmEngineLabel: String {
        config.llm.selectedModel?.name ?? ""
    }

    // MARK: - 历史记录（内联展开）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：左侧 caption，右侧计数字
            HStack {
                Text("历史记录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !historyItems.isEmpty {
                    Text("已记录 \(historyItems.count)/\(config.general.maxHistoryCount) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if historyItems.isEmpty {
                Text("暂无记录")
                    .font(.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(historyItems.prefix(5).enumerated()), id: \.element.id) { idx, item in
                    Button(action: { copyItem(item) }) {
                        HStack(spacing: 4) {
                            Text("\(idx + 1).")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .leading)
                            Text(item.llmResult ?? item.asrResult)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoveredItemID == item.id ? Color.primary.opacity(0.08) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
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

    private func bottomButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            // 退出按钮直接 terminate，不跑 dismiss 避免潜在的窗口释放冲突
            if title == "退出" {
                NSApp.terminate(nil)
                return
            }
            action()
            dismissMenuBarExtra()
        }) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// 在面板内显示临时提示，3 秒后自动消失。
    private func showToast(_ message: String) {
        toastWork?.cancel()
        toastMessage = message
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

    private var statusColor: Color {
        switch coordinator.sessionState {
        case .recording: return .red
        case .transcribing, .polishing: return .orange
        case .ready: return .green
        default: return .gray
        }
    }

    private func reloadHistory() {
        historyItems = HistoryStore.shared.items
    }
}

