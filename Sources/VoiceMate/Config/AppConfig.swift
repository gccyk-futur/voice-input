import Foundation

/// 全量配置模型，对应 PRD-2 的 config.json 结构。
/// 敏感字段（apiKey 等）在落盘时脱敏为 "****" 并存入 Keychain（见 ConfigStore）。
struct AppConfig: Codable {
    var version: String = "1.0"
    var general: GeneralConfig = .init()
    var asr: ASRConfig = .init()
    var llm: LLMConfig = .init()

    static var `default`: AppConfig { AppConfig() }
}

struct GeneralConfig: Codable {
    var hotkey: String = "Cmd+Shift+V"
    var launchAtStartup: Bool = false
    var windowStyle: String = "vibrancy"
    var maxHistoryCount: Int = 50
}

struct ASRConfig: Codable {
    var engine: String = "system" // system | whisper | iflytek | aliyun | openai-whisper
    var system: ASRSystemConfig = .init()
    var whisper: ASRWhisperConfig = .init()
    var iflytek: ASRIflytekConfig = .init()
    var aliyun: ASRAliyunConfig = .init()
    var openaiWhisper: ASROpenAIWhisperConfig = .init()
}

struct ASRSystemConfig: Codable { var language: String = "zh-Hans-CN" }
struct ASRWhisperConfig: Codable {
    var modelPath: String = ""
    var threads: Int = 4
    var language: String = "auto"
}
struct ASRIflytekConfig: Codable {
    var appId: String = ""
    var apiKey: String = ""
}
struct ASRAliyunConfig: Codable {
    var apiKey: String = ""
    var workspaceId: String = ""
    var model: String = "fun-asr-realtime"
    var semanticPunctuation: Bool = true
    var speechNoiseThreshold: Double = 0.0
    var maxSentenceSilence: Int = 1300
    var autoStopEnabled: Bool = true
    var autoStopTimeout: Double = 3.5
    var autoStopThreshold: Double = 0.01
}
struct ASROpenAIWhisperConfig: Codable {
    var apiKey: String = ""
    var model: String = "whisper-1"
}

struct LLMConfig: Codable {
    var enabled: Bool = false
    var engine: String = "ollama" // ollama | openai | deepseek | claude | custom
    var ollama: LLMOllamaConfig = .init()
    var openai: LLMOpenAIConfig = .init()
    var deepseek: LLMDeepSeekConfig = .init()
    var claude: LLMClaudeConfig = .init()
    var custom: LLMCustomConfig = .init()
    var prompt: LLMPromptConfig = .init()
}
struct LLMOllamaConfig: Codable {
    var baseUrl: String = "http://localhost:11434"
    var model: String = "qwen2.5:7b"
    var temperature: Double = 0.7
    var numPredict: Int = 512
}
struct LLMOpenAIConfig: Codable {
    var apiKey: String = ""
    var model: String = "gpt-4o-mini"
    var baseUrl: String = "https://api.openai.com/v1"
    var temperature: Double = 0.7
}
struct LLMDeepSeekConfig: Codable {
    var apiKey: String = ""
    var model: String = "deepseek-v4-flash"
    var baseUrl: String = "https://api.deepseek.com/v1"
    var temperature: Double = 0.7
}
struct LLMClaudeConfig: Codable {
    var apiKey: String = ""
    var model: String = "claude-3-5-sonnet-20241022"
    var baseUrl: String = "https://api.anthropic.com/v1"
    var temperature: Double = 0.7
}
struct LLMCustomConfig: Codable {
    var apiKey: String = ""
    var model: String = ""
    var baseUrl: String = ""
    var temperature: Double = 0.7
}
struct LLMPromptConfig: Codable {
    var system: String = "你是一个专业的文字润色助手，请将口语改写为书面语。"
    var user: String = "请将以下口语内容改写成正式书面中文：\n1. 去掉'嗯、啊、那个、就是说、其实'等口头禅\n2. 修正错别字和语法错误\n3. 保持原意不变\n4. 只输出改写后的文本，不要任何解释或前缀\n\n口语内容：{{input}}\n\n改写结果："
}
