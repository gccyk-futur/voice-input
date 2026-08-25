import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

private enum ContactInfo {
    static let email = "voicekit@ckai.me"
    static let website = "ckai.me/voice-kit"
    static let websiteURL = "https://ckai.me/voice-kit"
    static let github = "github.com/gccyk-futur/voice-input"
}

// MARK: - 关于（自 SettingsView.swift 机械拆出，逻辑未改动）

extension SettingsView {
    var aboutTab: some View {
        Group {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VoiceKit").font(typography.title).bold()
                        Text("macOS 语音输入助手 — 全局热键，说话即输入")
                            .font(typography.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(aboutVersionString)
                                .font(typography.callout).foregroundStyle(.secondary)
                            Text("·")
                                .font(typography.callout).foregroundStyle(.secondary)
#if APP_STORE
                            Text("App Store")
                                .font(typography.callout).foregroundStyle(.tint)
#else
                            Text("官网版")
                                .font(typography.callout).foregroundStyle(.secondary)
#endif
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 开源声明
            Section {
                Text("VoiceKit 是完全开源的软件，代码托管在 GitHub，任何人都可以查看、审计和参与改进。没有付费墙，没有隐藏费用，也不需要注册任何账号。")
                    .font(typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("开源免费 · 无需注册", systemImage: "lock.open")
            }

            // 联系与更新
            Section {
                contactRow(icon: "envelope.fill", value: ContactInfo.email)
                contactRow(icon: "safari.fill", value: ContactInfo.website, url: ContactInfo.websiteURL)
                contactRow(icon: "chevron.left.forwardslash.chevron.right", value: ContactInfo.github)
            } header: {
                Label("联系与更新", systemImage: "envelope")
            } footer: {
                Text("点击网站链接可在浏览器中打开；其他信息可用右侧按钮复制。\n\nCopyright © 2026 VoiceKit. MIT License.")
            }
        }
    }

    /// 从 Info.plist 读取版本号
    var aboutVersionString: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return VoiceKitLocalization.format("版本 %@ (build %@)", ver, build)
    }

    /// 联系行：传了 url 时值本身可点击（浏览器打开），否则纯展示 + 右侧复制。
    func contactRow(icon: String, value: String, url: String? = nil) -> some View {
        ContactRow(icon: icon, value: value, url: url)
    }
}

/// 联系行的值视图：可点击时用 Button + 悬浮下划线/手型光标表达链接心智。
private struct ContactRow: View {
    let icon: String
    let value: String
    let url: String?

    @Environment(\.voiceKitTextScale) private var textScale
    @State private var hovering = false

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(typography.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if let url, let target = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(target)
                } label: {
                    Text(value)
                        .font(typography.callout)
                        .foregroundStyle(hovering ? Color.accentColor : Color.primary)
                        .underline(hovering)
                }
                .buttonStyle(.plain)
                .voiceKitToolTip(VoiceKitLocalization.string("在浏览器中打开"))
                .onHover { h in
                    hovering = h
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            } else {
                Text(value)
                    .font(typography.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制")
            .accessibilityLabel(VoiceKitLocalization.format("复制 %@", value))
        }
    }
}
