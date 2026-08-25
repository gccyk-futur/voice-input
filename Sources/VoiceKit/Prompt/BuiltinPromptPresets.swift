import Foundation

/// 内置提示词预设库（可选导入，不强加）。
///
/// 设计：
/// - 正文统一英文 + 「跟随输入语言输出」指令，多语言只维护一套；
///   名称与说明走 10 语言本地化
/// - 导入即拷贝为用户预设（builtinID + builtinVersion 记录来源与库版本）；
///   库升级时未自定义的拷贝自动跟随（syncImportedPresets），改过一个字的永久脱钩
/// - 不依赖 {{language}} 配置值：多引擎下该值可能过期，输入语言永远是对的
struct BuiltinPromptPreset: Identifiable, Equatable {
    /// 固定 id（builtin.xxx），用于「已导入」检测
    let id: String
    /// 本地化 key（zh-Hans 源串）
    let nameKey: String
    let descriptionKey: String
    let system: String
    let user: String
    /// 库版本号：改动正文时 +1，并把旧正文挪到 previousSystem（一级历史）
    let version: Int
    /// 上一版正文：浮动机制据此判断用户拷贝是否「未被自定义」
    let previousSystem: String?

    var name: String { VoiceKitLocalization.string(nameKey) }
    var summary: String { VoiceKitLocalization.string(descriptionKey) }
}

enum BuiltinPromptPresets {

    /// 「跟随输入语言」指令：非翻译类预设统一以它收尾
    private static let followInputLanguage = "Always respond in the same language as the input transcript."

    /// 要点清单 v1 正文（首版库内容，供浮动机制比对）
    private static let keyPointsV1System = """
    You are an assistant that condenses spoken transcripts into a bullet-point list.
    Rules:
    1. Extract the key points, one per line.
    2. Keep each point short and faithful to what was said.
    3. Do not add information that was not said.
    4. Output only the list itself.
    \(followInputLanguage)
    """

    static let all: [BuiltinPromptPreset] = [
        BuiltinPromptPreset(
            id: "builtin.polish-deep",
            nameKey: "深度润色",
            descriptionKey: "在清理口语的基础上重组语句、理顺逻辑，输出更成形的文字。",
            system: """
            You are an editor that rewrites spoken transcripts into clear, well-structured text.
            Rules:
            1. Remove filler words, hesitations, and repetitions.
            2. Fix transcription errors and grammar issues.
            3. Reorganize sentences for clarity and flow when the spoken structure is messy.
            4. Keep the original meaning — do not add or omit information.
            5. Output only the rewritten text itself — no explanations, prefixes, or quotes.
            \(followInputLanguage)
            """,
            user: "Transcript: {{input}}",
            version: 1,
            previousSystem: nil
        ),
        BuiltinPromptPreset(
            id: "builtin.meeting-notes",
            nameKey: "会议纪要",
            descriptionKey: "把口语内容整理成带要点的结构化纪要。",
            system: """
            You are an assistant that turns spoken transcripts into clear meeting notes.
            Rules:
            1. Extract key decisions, discussion points, and action items.
            2. Use concise bullet points with section headings.
            3. Do not add information that was not said.
            4. Output only the notes themselves.
            \(followInputLanguage)
            """,
            user: "Transcript: {{input}}",
            version: 1,
            previousSystem: nil
        ),
        BuiltinPromptPreset(
            id: "builtin.key-points",
            nameKey: "要点清单",
            descriptionKey: "把口语内容提炼成一行一条的要点列表。",
            system: """
            You are an assistant that condenses spoken transcripts into a short bullet-point list.
            Rules:
            1. Start with a single line naming the topic.
            2. Then list the key points as flat bullets, one per line.
            3. No nesting, no numbering, no section headings, no sub-bullets.
            4. Keep each point short and faithful to what was said; do not add information.
            5. Output only the topic line and the bullets themselves.
            \(followInputLanguage)
            """,
            user: "Transcript: {{input}}",
            version: 2,
            previousSystem: keyPointsV1System
        ),
        BuiltinPromptPreset(
            id: "builtin.translate-en-casual",
            nameKey: "翻译成英文 · 日常",
            descriptionKey: "译成自然日常口吻的英文，适合聊天和社交。",
            system: """
            You are a translator. Translate the transcript into natural, casual English
            as used in everyday conversation and chats with friends.
            Keep the tone relaxed and idiomatic. Output only the translation itself.
            """,
            user: "Transcript: {{input}}",
            version: 1,
            previousSystem: nil
        ),
        BuiltinPromptPreset(
            id: "builtin.translate-en-business",
            nameKey: "翻译成英文 · 商务",
            descriptionKey: "译成正式得体的商务英文，适合邮件和职场沟通。",
            system: """
            You are a translator. Translate the transcript into professional business English
            suitable for emails and workplace communication.
            Keep the tone polite, concise, and formal. Output only the translation itself.
            """,
            user: "Transcript: {{input}}",
            version: 1,
            previousSystem: nil
        ),
        BuiltinPromptPreset(
            id: "builtin.formal-document",
            nameKey: "正式公文",
            descriptionKey: "改写为措辞严谨、格式规范的正式公文或邮件。",
            system: """
            You are an assistant that rewrites spoken transcripts as formal documents
            or official correspondence.
            Rules:
            1. Use formal, precise wording and proper document structure.
            2. Keep the original meaning — do not add or omit information.
            3. Output only the document text itself.
            \(followInputLanguage)
            """,
            user: "Transcript: {{input}}",
            version: 1,
            previousSystem: nil
        )
    ]
    /// 导入拷贝的浮动更新：库版本升级时，**未被用户改过**的拷贝自动跟随新正文；
    /// 改过一个字的立即脱钩、永久保留（逐字比对当前版或上一版正文来判定「未自定义」）。
    /// 在 LLMConfig.migrateFromLegacy() 里每次加载配置时调用。
    static func syncImportedPresets(_ prompts: inout [LLMPromptPreset]) {
        for i in prompts.indices {
            guard let builtinID = prompts[i].builtinID,
                  let preset = all.first(where: { $0.id == builtinID })
            else { continue }
            let copyVersion = prompts[i].builtinVersion ?? 1  // 版本字段加入前导入的拷贝视为 v1
            guard copyVersion < preset.version else { continue }
            let untouched = prompts[i].system == preset.system
                || (preset.previousSystem != nil && prompts[i].system == preset.previousSystem)
            guard untouched else { continue }
            prompts[i].system = preset.system
            prompts[i].user = preset.user
            prompts[i].builtinVersion = preset.version
        }
    }
}

/// 旧版出厂默认提示词（v1.1 及之前，10 语言本地化正文）。
/// 从各语言 Localizable.strings 读取旧 key 的译文——strings 里的旧条目是单一事实来源，
/// 代码里不硬编码 10 份译文（会撞 CJK 本地化守护测试）。
/// 用途：「默认提示词升级询问」检测用户是否仍在用旧出厂默认（逐字相等才询问）。
enum LegacyFactoryPolishPrompt {
    /// 旧出厂默认正文的本地化 key（zh-Hans 源串，仍保留在各语言 strings 中）
    static let legacyKey = "你是一个专业的文字润色助手，负责将语音转写的口语内容改写为规范、自然的书面中文。改写规则：\n1. 去掉「嗯、啊、那个、就是说、其实」等口头禅和语气词\n2. 修正错别字、语病和明显的语音识别错误\n3. 保持原意不变，不新增、不遗漏信息\n4. 只输出改写后的文本本身，不要任何解释、前缀或引号"

    /// 单测注入点：覆盖资源目录（测试 bundle 里没有 lproj）。
    nonisolated(unsafe) static var resourcesDirectoryOverride: URL?

    /// 旧默认的全部语言版本（从各 .lproj 的 strings 读取）。
    static func legacySystems() -> [String] {
        legacySystems(resourcesDirectory: resourcesDirectoryOverride ?? Bundle.main.resourceURL)
    }

    /// - Parameter resourcesDirectory: 含各语言 .lproj 的目录。
    static func legacySystems(resourcesDirectory: URL?) -> [String] {
        guard let resourcesDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: resourcesDirectory.path)
        else { return [] }
        var result: [String] = []
        for entry in entries.sorted() where entry.hasSuffix(".lproj") {
            let url = resourcesDirectory
                .appendingPathComponent(entry)
                .appendingPathComponent("Localizable.strings")
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String],
                  let value = dict[legacyKey]
            else { continue }
            result.append(value)
        }
        return result
    }
}
