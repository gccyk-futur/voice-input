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
    var enabled: Bool = true
    var startSound: String = "Tink"
    var stopSound: String = "Purr"
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
struct LLMConfig: Codable, Equatable {
    var enabled: Bool = false
    var engine: String = "ollama" // ollama | openai
    var ollama: LLMOllamaConfig = .init()
    var openai: LLMOpenAIConfig = .init()
    var prompt: LLMPromptConfig = .init()
}
struct LLMOllamaConfig: Codable, Equatable {
    var baseUrl: String = "http://localhost:11434"
    var model: String = "qwen2.5:7b"
    var temperature: Double = 0.7
    var numPredict: Int = 512
}
struct LLMOpenAIConfig: Codable, Equatable {
    var apiKey: String = ""
    var model: String = "gpt-4o-mini"
    var baseUrl: String = "https://api.openai.com/v1"
    var temperature: Double = 0.7
}
struct LLMPromptConfig: Codable, Equatable {
    var system: String = "你是一个专业的文字润色助手，请将口语改写为书面语。"
    var user: String = "请将以下口语内容改写成正式书面中文：\n1. 去掉'嗯、啊、那个、就是说、其实'等口头禅\n2. 修正错别字和语法错误\n3. 保持原意不变\n4. 只输出改写后的文本，不要任何解释或前缀\n\n口语内容：{{input}}\n\n改写结果："
}
