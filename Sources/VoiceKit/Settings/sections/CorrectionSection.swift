import SwiftUI

extension SettingsView {
    /// 设置→词汇纠正 独立分页：总开关 + 规则管理 Sheet。
    var correctionTab: some View {
        CorrectionSettingsSectionView(draft: $draft)
    }
}

/// 「词汇纠正」分区：总开关 + 规则管理 Sheet。
/// 引擎无关：对最终识别文本统一生效（进 LLM 润色 / 粘贴 / 历史之前）。
struct CorrectionSettingsSectionView: View {
    @Binding var draft: AppConfig

    @State private var showEditor = false

    var body: some View {
        Section {
            Toggle("启用词汇纠正", isOn: $draft.asr.correction.enabled)
            HStack {
                Text(VoiceKitLocalization.format("%lld 条规则", draft.asr.correction.rules.count))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("管理替换规则…") { showEditor = true }
            }
        } header: {
            Text("词汇纠正")
        } footer: {
            Text(VoiceKitLocalization.string("把引擎容易听错的词自动替换为正确写法（如“cloud code”纠正为“Claude Code”），对所有识别引擎生效。"))
        }
        .sheet(isPresented: $showEditor) {
            CorrectionRulesSheet(rules: $draft.asr.correction.rules)
        }
    }
}

// MARK: - 替换规则编辑 Sheet

struct CorrectionRulesSheet: View {
    @Binding var rules: [CorrectionRule]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceKitTextScale) private var textScale

    private var typography: VoiceKitTypography { VoiceKitTypography(scale: textScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("替换规则").font(typography.sectionTitle)
            Text(VoiceKitLocalization.string("左侧填引擎容易听错的写法，右侧填要替换成的正确写法。"))
                .font(typography.callout)
                .foregroundStyle(.secondary)

            if rules.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(VoiceKitLocalization.string("还没有规则"))
                        .font(typography.body)
                        .foregroundStyle(.secondary)
                    Text(VoiceKitLocalization.string("例如：识别为 cloud code → 替换为 Claude Code"))
                        .font(typography.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // 列头
                HStack(spacing: 8) {
                    Text("识别为").font(typography.metadata).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("替换为").font(typography.metadata).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($rules) { $rule in
                            HStack(spacing: 8) {
                                TextField("cloud code", text: $rule.match)
                                    .textFieldStyle(.roundedBorder)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                TextField("Claude Code", text: $rule.replacement)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    rules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(VoiceKitLocalization.string("删除规则"))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                Button {
                    rules.append(CorrectionRule())
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}
