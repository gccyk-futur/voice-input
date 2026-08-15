import Foundation

/// 全量配置模型，对应 PRD-2 的 config.json 结构。
/// 敏感字段（apiKey 等）以明文落盘于 config.json（本地个人工具，见 ConfigStore 注释）。
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
    /// 使用统计：仅记录时长、字数、引擎等元数据，不含任何文字内容，仅存本机。
    /// 默认开启——统计模块依赖历史数据，默认关闭会导致功能上线时一片空白；
    /// 且其敏感度低于始终开启的运行日志（后者含转录原文）。
    var usageStatsEnabled: Bool = true
    /// 识别文字在剪贴板中的保留时长（秒）；0 = 永不还原（等同普通复制，默认）。
    /// 仅作用于"未自动投递、需用户手动 ⌘V"的路径（writeClipboardOnly）；
    /// paste() 自动投递借用剪贴板的场景固定 8 秒还原，见 PasteDeliveryPolicy。
    var clipboardRetentionSeconds: Double = 0
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
    var engine: String = "system" // system | aliyun | xunfei | deepgram
    var system: ASRSystemConfig = .init()
    var aliyun: ASRAliyunConfig = .init()
    var xunfei: ASRXunfeiConfig = .init()
    var deepgram: ASRDeepgramConfig = .init()
}

struct ASRSystemConfig: Codable, Equatable {
    var language: String = "zh-Hans-CN"
    var silenceAutoStopEnabled: Bool = false
    var silenceTimeout: Double = 2.0
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
    var autoStopTimeout: Double = 5.0
}
struct ASRXunfeiConfig: Codable, Equatable {
    var appId: String = ""
    var apiKey: String = ""
    var apiSecret: String = ""
    /// 动态修正（wpgs）：已返回的中间结果可被后续结果修正，仅中文支持
    var dynamicCorrection: Bool = true
    var autoStopEnabled: Bool = true
    var autoStopTimeout: Double = 5.0
}
struct ASRDeepgramConfig: Codable, Equatable {
    var apiKey: String = ""
    var model: String = "nova-3"
    var autoStopEnabled: Bool = true
    var autoStopTimeout: Double = 5.0
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

// MARK: - 宽容解码（向后兼容旧版 config.json）
//
// 合成 Codable 要求所有非可选字段的 key 必须存在，新增配置字段会导致旧版
// config.json 整体解码失败、用户配置被静默重置为默认值。这里为每个配置结构
// 提供自定义 init(from:)：缺失的 key 一律回退到默认值。

private extension KeyedDecodingContainer {
    /// key 缺失或值为 null 时回退到默认值。
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default def: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? def()
    }
}

extension AppConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        version = try c.decode(String.self, forKey: .version, default: d.version)
        general = try c.decode(GeneralConfig.self, forKey: .general, default: d.general)
        asr = try c.decode(ASRConfig.self, forKey: .asr, default: d.asr)
        llm = try c.decode(LLMConfig.self, forKey: .llm, default: d.llm)
    }
}

extension GeneralConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralConfig()
        hotkey = try c.decode(String.self, forKey: .hotkey, default: d.hotkey)
        launchAtStartup = try c.decode(Bool.self, forKey: .launchAtStartup, default: d.launchAtStartup)
        showSettingsOnLaunch = try c.decode(Bool.self, forKey: .showSettingsOnLaunch, default: d.showSettingsOnLaunch)
        windowStyle = try c.decode(String.self, forKey: .windowStyle, default: d.windowStyle)
        maxHistoryCount = try c.decode(Int.self, forKey: .maxHistoryCount, default: d.maxHistoryCount)
        usageStatsEnabled = try c.decode(Bool.self, forKey: .usageStatsEnabled, default: d.usageStatsEnabled)
        clipboardRetentionSeconds = try c.decode(Double.self, forKey: .clipboardRetentionSeconds, default: d.clipboardRetentionSeconds)
        sound = try c.decode(SoundConfig.self, forKey: .sound, default: d.sound)
    }
}

extension SoundConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SoundConfig()
        enabled = try c.decode(Bool.self, forKey: .enabled, default: d.enabled)
        startEnabled = try c.decodeIfPresent(Bool.self, forKey: .startEnabled)
        stopEnabled = try c.decodeIfPresent(Bool.self, forKey: .stopEnabled)
        startSound = try c.decode(String.self, forKey: .startSound, default: d.startSound)
        stopSound = try c.decode(String.self, forKey: .stopSound, default: d.stopSound)
    }
}

extension ASRConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ASRConfig()
        engine = try c.decode(String.self, forKey: .engine, default: d.engine)
        system = try c.decode(ASRSystemConfig.self, forKey: .system, default: d.system)
        aliyun = try c.decode(ASRAliyunConfig.self, forKey: .aliyun, default: d.aliyun)
        xunfei = try c.decode(ASRXunfeiConfig.self, forKey: .xunfei, default: d.xunfei)
        deepgram = try c.decode(ASRDeepgramConfig.self, forKey: .deepgram, default: d.deepgram)
    }
}

extension ASRSystemConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ASRSystemConfig()
        language = try c.decode(String.self, forKey: .language, default: d.language)
        silenceAutoStopEnabled = try c.decode(Bool.self, forKey: .silenceAutoStopEnabled, default: d.silenceAutoStopEnabled)
        silenceTimeout = try c.decode(Double.self, forKey: .silenceTimeout, default: d.silenceTimeout)
    }
}

extension ASRAliyunConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ASRAliyunConfig()
        apiKey = try c.decode(String.self, forKey: .apiKey, default: d.apiKey)
        workspaceId = try c.decode(String.self, forKey: .workspaceId, default: d.workspaceId)
        region = try c.decode(String.self, forKey: .region, default: d.region)
        model = try c.decode(String.self, forKey: .model, default: d.model)
        semanticPunctuation = try c.decode(Bool.self, forKey: .semanticPunctuation, default: d.semanticPunctuation)
        speechNoiseThreshold = try c.decode(Double.self, forKey: .speechNoiseThreshold, default: d.speechNoiseThreshold)
        maxSentenceSilence = try c.decode(Int.self, forKey: .maxSentenceSilence, default: d.maxSentenceSilence)
        autoStopEnabled = try c.decode(Bool.self, forKey: .autoStopEnabled, default: d.autoStopEnabled)
        autoStopTimeout = try c.decode(Double.self, forKey: .autoStopTimeout, default: d.autoStopTimeout)
    }
}

extension ASRXunfeiConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ASRXunfeiConfig()
        appId = try c.decode(String.self, forKey: .appId, default: d.appId)
        apiKey = try c.decode(String.self, forKey: .apiKey, default: d.apiKey)
        apiSecret = try c.decode(String.self, forKey: .apiSecret, default: d.apiSecret)
        dynamicCorrection = try c.decode(Bool.self, forKey: .dynamicCorrection, default: d.dynamicCorrection)
        autoStopEnabled = try c.decode(Bool.self, forKey: .autoStopEnabled, default: d.autoStopEnabled)
        autoStopTimeout = try c.decode(Double.self, forKey: .autoStopTimeout, default: d.autoStopTimeout)
    }
}

extension ASRDeepgramConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ASRDeepgramConfig()
        apiKey = try c.decode(String.self, forKey: .apiKey, default: d.apiKey)
        model = try c.decode(String.self, forKey: .model, default: d.model)
        autoStopEnabled = try c.decode(Bool.self, forKey: .autoStopEnabled, default: d.autoStopEnabled)
        autoStopTimeout = try c.decode(Double.self, forKey: .autoStopTimeout, default: d.autoStopTimeout)
    }
}

extension LLMModelDef {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMModelDef()
        id = try c.decode(String.self, forKey: .id, default: d.id)
        name = try c.decode(String.self, forKey: .name, default: d.name)
        engine = try c.decode(String.self, forKey: .engine, default: d.engine)
        baseUrl = try c.decode(String.self, forKey: .baseUrl, default: d.baseUrl)
        apiKey = try c.decode(String.self, forKey: .apiKey, default: d.apiKey)
        model = try c.decode(String.self, forKey: .model, default: d.model)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens, default: d.totalTokens)
        usageCount = try c.decode(Int.self, forKey: .usageCount, default: d.usageCount)
    }
}

extension LLMConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMConfig()
        enabled = try c.decode(Bool.self, forKey: .enabled, default: d.enabled)
        temperature = try c.decode(Double.self, forKey: .temperature, default: d.temperature)
        selectedModelID = try c.decode(String.self, forKey: .selectedModelID, default: d.selectedModelID)
        models = try c.decode([LLMModelDef].self, forKey: .models, default: d.models)
        prompt = try c.decode(LLMPromptConfig.self, forKey: .prompt, default: d.prompt)
        prompts = try c.decode([LLMPromptPreset].self, forKey: .prompts, default: d.prompts)
        selectedPromptID = try c.decode(String.self, forKey: .selectedPromptID, default: d.selectedPromptID)
        engine = try c.decode(String.self, forKey: .engine, default: d.engine)
        ollama = try c.decode(LLMOllamaConfig.self, forKey: .ollama, default: d.ollama)
        openai = try c.decode(LLMOpenAIConfig.self, forKey: .openai, default: d.openai)
    }
}

extension LLMOllamaConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMOllamaConfig()
        baseUrl = try c.decode(String.self, forKey: .baseUrl, default: d.baseUrl)
        model = try c.decode(String.self, forKey: .model, default: d.model)
        temperature = try c.decode(Double.self, forKey: .temperature, default: d.temperature)
        numPredict = try c.decode(Int.self, forKey: .numPredict, default: d.numPredict)
    }
}

extension LLMOpenAIConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMOpenAIConfig()
        apiKey = try c.decode(String.self, forKey: .apiKey, default: d.apiKey)
        model = try c.decode(String.self, forKey: .model, default: d.model)
        baseUrl = try c.decode(String.self, forKey: .baseUrl, default: d.baseUrl)
        temperature = try c.decode(Double.self, forKey: .temperature, default: d.temperature)
    }
}

extension LLMPromptConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMPromptConfig()
        system = try c.decode(String.self, forKey: .system, default: d.system)
        user = try c.decode(String.self, forKey: .user, default: d.user)
    }
}

extension LLMPromptPreset {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMPromptPreset()
        id = try c.decode(String.self, forKey: .id, default: d.id)
        name = try c.decode(String.self, forKey: .name, default: d.name)
        system = try c.decode(String.self, forKey: .system, default: d.system)
        user = try c.decode(String.self, forKey: .user, default: d.user)
    }
}
