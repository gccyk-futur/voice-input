import Foundation

/// 全量配置模型，对应 PRD-2 的 config.json 结构。
/// 敏感字段（apiKey 等）在落盘时脱敏为 "****" 并存入 Keychain（见 ConfigStore）。
struct AppConfig: Codable, Equatable {
    var version: String = "1.0"
    var general: GeneralConfig = .init()
    var asr: ASRConfig = .init()
    var llm: LLMConfig = .init()

    static var `default`: AppConfig { AppConfig() }
}

struct GeneralConfig: Codable, Equatable {
    var hotkey: String = "Cmd+Shift+V"
    var launchAtStartup: Bool = false
    var showSettingsOnLaunch: Bool = true
    var windowStyle: String = "vibrancy"
    var maxHistoryCount: Int = 50
    var sound: SoundConfig = .init()
}

struct SoundConfig: Codable, Equatable {
    /// legacy 总开关（仅用于兼容旧配置，新逻辑不再读取）
    var enabled: Bool = true
    /// 开始录音提示音开关；nil 表示旧配置未迁移，回退到 legacy 总开关
    var startEnabled: Bool? = nil
    /// 识别完成提示音开关；nil 表示旧配置未迁移，回退到 legacy 总开关
    var stopEnabled: Bool? = nil
    var startSound: String = "Frog"
    var stopSound: String = "Funk"

    /// 运行时统一读取入口
    var start: Bool { startEnabled ?? enabled }
    var stop: Bool { stopEnabled ?? enabled }
}

struct ASRConfig: Codable, Equatable {
    var engine: String = "system" // system | aliyun
    var system: ASRSystemConfig = .init()
    var aliyun: ASRAliyunConfig = .init()
}

struct ASRSystemConfig: Codable, Equatable {
    var language: String = "zh-Hans-CN"
    var silenceAutoStopEnabled: Bool = false
    var silenceTimeout: Double = 2.0
    var silenceThreshold: Double = 0.02
}
struct ASRAliyunConfig: Codable, Equatable {
    var apiKey: String = ""
    var workspaceId: String = ""
    var region: String = "cn-beijing"
    var model: String = "fun-asr-realtime"
    var semanticPunctuation: Bool = true
    var speechNoiseThreshold: Double = 0.0
    var maxSentenceSilence: Int = 1300
    var autoStopEnabled: Bool = true
    var autoStopTimeout: Double = 3.5
    var autoStopThreshold: Double = 0.01
}
/// LLM 模型定义：用户可自由增删多个模型配置。
struct LLMModelDef: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var engine: String = "openai" // "openai" | "ollama"
    var baseUrl: String = ""
    var apiKey: String = ""
    var model: String = ""
    /// 累计 token 数（运行中自动统计并持久化）
    var totalTokens: Int = 0
    /// 使用次数
    var usageCount: Int = 0
}

struct LLMConfig: Codable, Equatable {
    var enabled: Bool = false
    var temperature: Double = 0.7
    var selectedModelID: String = ""
    var models: [LLMModelDef] = []
    var prompt: LLMPromptConfig = .init()
    var prompts: [LLMPromptPreset] = []
    var selectedPromptID: String = ""

    // Legacy fields（仅用于迁移，v2 不再主动写入）
    var engine: String = "ollama"
    var ollama: LLMOllamaConfig = .init()
    var openai: LLMOpenAIConfig = .init()

    var selectedModel: LLMModelDef? {
        models.first { $0.id == selectedModelID } ?? models.first
    }

    var selectedPrompt: LLMPromptPreset? {
        prompts.first { $0.id == selectedPromptID }
    }

    /// 运行时统一读取入口：选中了用户预设则用预设，否则用系统默认提示词。
    /// llm.prompt 是出厂默认（列表第一条，可编辑但不可删除）；
    /// prompts[] 只存放用户自建的预设。ASR/润色流程只读这里。
    var activePrompt: LLMPromptConfig {
        if let p = selectedPrompt {
            return LLMPromptConfig(system: p.system, user: p.user)
        }
        return prompt
    }

    /// 从旧版单模型配置迁移到多模型数组（仅首次执行）。
    mutating func migrateFromLegacy() {
        guard models.isEmpty else { return }
        if engine == "openai", !openai.baseUrl.isEmpty {
#if APP_STORE
            let m = LLMModelDef(
                name: "云端 API", engine: "openai",
                baseUrl: openai.baseUrl, apiKey: openai.apiKey,
                model: openai.model
            )
#else
            let m = LLMModelDef(
                name: "OpenAI", engine: "openai",
                baseUrl: openai.baseUrl, apiKey: openai.apiKey,
                model: openai.model
            )
#endif
            models.append(m)
            selectedModelID = m.id
        } else if engine == "ollama", !ollama.baseUrl.isEmpty {
            let m = LLMModelDef(
                name: "Ollama", engine: "ollama",
                baseUrl: ollama.baseUrl, apiKey: "",
                model: ollama.model
            )
            models.append(m)
            selectedModelID = m.id
        }
    }
}
struct LLMOllamaConfig: Codable, Equatable {
    var baseUrl: String = "http://localhost:11434"
    var model: String = "qwen2.5:7b"
    var temperature: Double = 0.7
    var numPredict: Int = 512
}
struct LLMOpenAIConfig: Codable, Equatable {
    var apiKey: String = ""
#if APP_STORE
    var model: String = ""
    var baseUrl: String = ""
#else
    var model: String = "gpt-4o-mini"
    var baseUrl: String = "https://api.openai.com/v1"
#endif
    var temperature: Double = 0.7
}
struct LLMPromptConfig: Codable, Equatable {
    var system: String = VoiceKitLocalization.string("你是一个专业的文字润色助手，负责将语音转写的口语内容改写为规范、自然的书面中文。改写规则：\n1. 去掉「嗯、啊、那个、就是说、其实」等口头禅和语气词\n2. 修正错别字、语病和明显的语音识别错误\n3. 保持原意不变，不新增、不遗漏信息\n4. 只输出改写后的文本本身，不要任何解释、前缀或引号")
    var user: String = VoiceKitLocalization.string("口语内容：{{input}}")
}

/// 提示词预设：用户可维护多套提示词并在设置/状态栏菜单中快速切换。
struct LLMPromptPreset: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "默认"
    var system: String = ""
    var user: String = ""
}
