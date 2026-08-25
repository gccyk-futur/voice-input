import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - 隐私与本地数据（自 SettingsView.swift 机械拆出，逻辑未改动）

extension SettingsView {
    var privacyTab: some View {
        Group {
            Section("你决定数据去哪里") {
                privacyRow(icon: "house.fill", color: .green,
                           title: "系统听写",
                           detail: "使用 macOS 内置语音识别，语音由系统处理。")
                privacyRow(icon: "cloud.fill", color: .blue,
                           title: "阿里云 Fun-ASR",
                           detail: "语音直接发送到你自己配置的阿里云服务实例。")
                privacyRow(icon: "cloud.fill", color: .blue,
                           title: "讯飞听写",
                           detail: "语音直接发送到你自己配置的讯飞开放平台账号。")
                privacyRow(icon: "cloud.fill", color: .blue,
                           title: "Deepgram",
                           detail: "语音直接发送到你自己配置的 Deepgram 账号。")
                privacyRow(icon: "cpu.fill", color: .orange,
                           title: "AI 润色",
                           detail: "识别文字直接发送到你配置的云端 API 或本地模型。使用本地模型时，文字不会离开这台 Mac。")
            }

            Section {
                Text("除了你自己配置的语音识别和 AI 服务，VoiceKit 不调用其他 API 服务。没有后台服务器，不会把语音、文字或任何使用数据上传到别处，也不追踪用户行为。")
                    .font(typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("VoiceKit 不提供中转服务", systemImage: "hand.raised.fill")
            } footer: {
                Text("API Key、模型地址和提示词只保存在本机配置中，并按你的设置使用。")
            }

            Section {
                localDataRow(title: "配置", file: "config.json",
                             detail: "偏好设置与 API 密钥（明文保存）",
                             url: Self.supportFileURL("config.json"))
                localDataRow(title: "历史记录", file: "history.json",
                             detail: "最近若干条识别原文与润色结果",
                             url: Self.supportFileURL("history.json"), clearable: true)
                localDataRow(title: "快照", file: "snapshots.json",
                             detail: "你手动保存、可反复速插的文本片段，不会自动清理",
                             url: Self.supportFileURL("snapshots.json"), clearable: true,
                             clear: { SnapshotStore.shared.clear(); refreshLocalDataSizes() })
                localDataRow(title: "运行日志", file: "voicekit.log",
                             detail: "含转录原文，仅用于排查问题，超过 2MB 自动覆盖较早内容",
                             url: Log.currentFileURL, clearable: true,
                             clear: { Log.clear(); refreshLocalDataSizes() })

                Toggle(isOn: Binding(
                    get: { draft.general.usageStatsEnabled },
                    set: { draft.general.usageStatsEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VoiceKitLocalization.string("记录使用统计"))
                            .font(typography.body)
                        Text(VoiceKitLocalization.string("stats.jsonl —— 仅记录时长、字数、引擎等元数据，不含任何文字内容"))
                            .font(typography.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text(VoiceKitLocalization.string("统计文件"))
                        .font(typography.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.formatBytes(localDataSizes["stats"] ?? 0))
                        .font(typography.callout).foregroundStyle(.secondary)
                    Button(VoiceKitLocalization.string("导出…")) { exportUsageStats() }
                        .controlSize(.small)
                    Button(VoiceKitLocalization.string("清空")) {
                        pendingClearTitle = VoiceKitLocalization.format("确定要清空「%@」吗？此操作不可逆。", VoiceKitLocalization.string("统计文件"))
                        pendingClearAction = {
                            UsageStatsStore.shared.clear()
                            refreshLocalDataSizes()
                        }
                    }
                    .controlSize(.small)
                }
            } header: {
                Label("本地数据", systemImage: "internaldrive")
            } footer: {
                Text("以上文件只存在于这台 Mac 上。VoiceKit 没有服务器，不会上传其中任何内容。")
            }
        }
        .task { refreshLocalDataSizes() }
    }

    // MARK: - 本地数据

    static func supportFileURL(_ name: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoiceMate", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "—" }
        let units = ["B", "KB", "MB"]
        var value = Double(bytes), idx = 0
        while value >= 1024, idx < units.count - 1 { value /= 1024; idx += 1 }
        return String(format: idx == 0 ? "%.0f %@" : "%.1f %@", value, units[idx])
    }

    func refreshLocalDataSizes() {
        func size(_ url: URL?) -> UInt64 {
            guard let url,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
            return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        }
        localDataSizes = [
            "config.json": size(Self.supportFileURL("config.json")),
            "history.json": size(Self.supportFileURL("history.json")),
            "snapshots.json": size(Self.supportFileURL("snapshots.json")),
            "voicekit.log": size(Log.currentFileURL),
            "stats": UsageStatsStore.shared.fileSize
        ]
    }

    func exportUsageStats() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voicekit-usage.jsonl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? UsageStatsStore.shared.export(to: dest)
    }

    @ViewBuilder
    func localDataRow(title: String, file: String, detail: String,
                              url: URL?, clearable: Bool = false,
                              clear: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceKitLocalization.string(title)).font(typography.body)
                Text(VoiceKitLocalization.string(detail))
                    .font(typography.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Self.formatBytes(localDataSizes[file] ?? 0))
                .font(typography.callout).foregroundStyle(.secondary)
            if let url {
                Button(VoiceKitLocalization.string("显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
            if clearable {
                Button(VoiceKitLocalization.string("清空")) {
                    pendingClearTitle = VoiceKitLocalization.format("确定要清空「%@」吗？此操作不可逆。", title)
                    pendingClearAction = {
                        if let clear { clear() }
                        else if let url {
                            try? FileManager.default.removeItem(at: url)
                            refreshLocalDataSizes()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    func privacyRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceKitLocalization.string(title)).font(typography.body.bold())
                Text(VoiceKitLocalization.string(detail))
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
