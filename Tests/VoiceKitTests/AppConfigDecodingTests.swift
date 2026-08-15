import XCTest
@testable import VoiceKit

/// 旧版 config.json 兼容性：已发布版本写出的配置缺少后续新增的字段
/// （如 asr.xunfei / asr.deepgram），解码必须成功并保留用户已有配置，
/// 新增字段回退默认值，而不是整份配置被静默重置。
final class AppConfigDecodingTests: XCTestCase {

    /// 模拟旧版本写出的 config.json：没有 xunfei/deepgram 节点，
    /// general/llm 也只有当时存在的字段。
    private let legacyJSON = """
    {
      "version": "1.0",
      "general": {
        "hotkey": "Cmd+Shift+R",
        "launchAtStartup": true,
        "showSettingsOnLaunch": false,
        "maxHistoryCount": 80
      },
      "asr": {
        "engine": "aliyun",
        "system": { "language": "zh-Hans-CN" },
        "aliyun": { "apiKey": "sk-legacy-key", "workspaceId": "ws-1", "region": "cn-shanghai" }
      },
      "llm": {
        "enabled": true,
        "engine": "openai",
        "openai": { "apiKey": "legacy-openai-key", "model": "gpt-4o-mini", "baseUrl": "https://api.openai.com/v1", "temperature": 0.7 },
        "models": [
          { "id": "m1", "name": "OpenAI", "engine": "openai", "baseUrl": "https://api.openai.com/v1", "apiKey": "k", "model": "gpt-4o-mini" }
        ],
        "selectedModelID": "m1"
      }
    }
    """

    func testLegacyConfigWithoutNewEngineKeysDecodesAndPreservesUserSettings() throws {
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        var config = try JSONDecoder().decode(AppConfig.self, from: data)
        config.llm.migrateFromLegacy()

        // 用户已有配置必须保留
        XCTAssertEqual(config.general.hotkey, "Cmd+Shift+R")
        XCTAssertTrue(config.general.launchAtStartup)
        XCTAssertEqual(config.general.maxHistoryCount, 80)
        XCTAssertEqual(config.asr.engine, "aliyun")
        XCTAssertEqual(config.asr.aliyun.apiKey, "sk-legacy-key")
        XCTAssertEqual(config.asr.aliyun.workspaceId, "ws-1")
        XCTAssertEqual(config.asr.aliyun.region, "cn-shanghai")
        XCTAssertEqual(config.llm.models.map(\.id), ["m1"])
        XCTAssertEqual(config.llm.models.first?.totalTokens, 0)

        // 新增字段回退默认值
        XCTAssertEqual(config.asr.xunfei, ASRXunfeiConfig())
        XCTAssertEqual(config.asr.deepgram, ASRDeepgramConfig())
        XCTAssertEqual(config.general.windowStyle, "vibrancy")
        XCTAssertEqual(config.general.sound, SoundConfig())
        XCTAssertTrue(config.asr.aliyun.autoStopEnabled)
        // 静音判定改自适应后，默认超时从 3.5 调整为 5.0（见 AppConfig 默认值）
        XCTAssertEqual(config.asr.aliyun.autoStopTimeout, 5.0)
    }

    func testRoundTripProducesDecodableConfig() throws {
        var config = AppConfig()
        config.asr.engine = "xunfei"
        config.asr.xunfei.appId = "app-1"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    /// 旧版配置没有 clipboardRetentionSeconds：解码回退到 0（永不还原），
    /// 不能因此导致整份配置解码失败被重置。
    func testLegacyConfigWithoutClipboardRetentionDecodesToNeverRestore() throws {
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(config.general.clipboardRetentionSeconds, 0)
    }

    /// 用户选择的保留时长必须能完整持久化往返。
    func testClipboardRetentionRoundTripPreservesUserChoice() throws {
        var config = AppConfig()
        config.general.clipboardRetentionSeconds = 30
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.general.clipboardRetentionSeconds, 30)
    }
}
