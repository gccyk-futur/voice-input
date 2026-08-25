import XCTest
@testable import VoiceKit

/// 内置提示词预设库 + 导入拷贝的版本浮动机制。
final class BuiltinPromptPresetsTests: XCTestCase {

    // MARK: - 预设库定义

    /// 内置预设 id 必须唯一且带 builtin. 前缀（「已导入」检测依赖它）。
    func testPresetIDsAreUniqueAndPrefixed() {
        let ids = BuiltinPromptPresets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("builtin.") })
    }

    /// 每个预设都必须能渲染：{{input}} 被替换，正文非空。
    func testEveryPresetRendersWithInputSubstitution() {
        for preset in BuiltinPromptPresets.all {
            let tmpl = PromptTemplate(system: preset.system, user: preset.user)
            let (sys, usr) = tmpl.render(input: "今天天气不错", language: "zh-Hans-CN", engine: "openai")
            XCTAssertFalse(sys.isEmpty, "\(preset.id) system 为空")
            XCTAssertTrue(usr.contains("今天天气不错"), "\(preset.id) 的 {{input}} 未被替换")
            XCTAssertFalse(usr.contains("{{input}}"), "\(preset.id) 残留占位符")
        }
    }

    /// 非翻译类预设必须带「跟随输入语言输出」指令——这是多语言单套正文的关键。
    /// 翻译类预设目标语言明确（英文），不需要这句。
    func testNonTranslationPresetsFollowInputLanguage() {
        let translationIDs: Set<String> = ["builtin.translate-en-casual", "builtin.translate-en-business"]
        for preset in BuiltinPromptPresets.all where !translationIDs.contains(preset.id) {
            XCTAssertTrue(
                preset.system.contains("same language as the input transcript"),
                "\(preset.id) 缺少跟随输入语言指令"
            )
        }
    }

    /// 版本号约束：改动过正文的预设必须 version > 1 且带 previousSystem（浮动机制依赖）。
    func testVersionedPresetsCarryPreviousBody() {
        for preset in BuiltinPromptPresets.all where preset.version > 1 {
            XCTAssertNotNil(preset.previousSystem, "\(preset.id) 升版但缺少上一版正文")
            XCTAssertNotEqual(preset.previousSystem, preset.system, "\(preset.id) 升版但正文未变")
        }
    }

    // MARK: - 出厂默认不迁移（产品决定）

    /// 升级不改写用户配置里已生效的默认提示词：即便是旧版中文出厂默认也原样保留。
    /// 新默认只服务新安装与「恢复默认设置」。
    func testFactoryDefaultIsNeverMigrated() throws {
        let json = """
        {
          "version": "1.0",
          "llm": {
            "enabled": true,
            "prompt": {
              "system": "你是一个专业的文字润色助手，负责将语音转写的口语内容改写为规范、自然的书面中文。改写规则：\\n1. 去掉「嗯、啊、那个、就是说、其实」等口头禅和语气词\\n2. 修正错别字、语病和明显的语音识别错误\\n3. 保持原意不变，不新增、不遗漏信息\\n4. 只输出改写后的文本本身，不要任何解释、前缀或引号",
              "user": "口语内容：{{input}}"
            },
            "models": [
              { "id": "m1", "name": "OpenAI", "engine": "openai", "baseUrl": "https://api.openai.com/v1", "apiKey": "k", "model": "gpt-4o-mini" }
            ],
            "selectedModelID": "m1"
          }
        }
        """
        var config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        config.llm.migrateFromLegacy()

        XCTAssertTrue(config.llm.prompt.system.contains("文字润色助手"))
        XCTAssertEqual(config.llm.prompt.user, "口语内容：{{input}}")
    }

    // MARK: - 导入拷贝的版本浮动

    /// 未自定义的导入拷贝：库升版后自动跟随新正文。
    func testUntouchedImportedCopyFloatsToLatestVersion() throws {
        let preset = try XCTUnwrap(BuiltinPromptPresets.all.first { $0.id == "builtin.key-points" })
        let previous = try XCTUnwrap(preset.previousSystem)
        // 模拟 v1 时代导入的拷贝（版本字段加入前导入的视为 v1）
        var prompts = [LLMPromptPreset(name: "要点清单", system: previous, user: "Transcript: {{input}}",
                                       builtinID: preset.id, builtinVersion: nil)]

        BuiltinPromptPresets.syncImportedPresets(&prompts)

        XCTAssertEqual(prompts[0].system, preset.system)
        XCTAssertEqual(prompts[0].builtinVersion, preset.version)
    }

    /// 用户改过一个字的拷贝立即脱钩：库升版也不动它。
    func testCustomizedImportedCopyNeverFloats() throws {
        let preset = try XCTUnwrap(BuiltinPromptPresets.all.first { $0.id == "builtin.key-points" })
        let previous = try XCTUnwrap(preset.previousSystem)
        var prompts = [LLMPromptPreset(name: "我的清单", system: previous + "\n再活泼一点",
                                       user: "Transcript: {{input}}",
                                       builtinID: preset.id, builtinVersion: 1)]

        BuiltinPromptPresets.syncImportedPresets(&prompts)

        XCTAssertTrue(prompts[0].system.hasSuffix("再活泼一点"))
        XCTAssertEqual(prompts[0].builtinVersion, 1)
        XCTAssertEqual(prompts[0].name, "我的清单")
    }

    /// 已在最新版本的拷贝不受影响；浮动幂等。
    func testFloatIsIdempotentAndSkipsCurrent() throws {
        let preset = try XCTUnwrap(BuiltinPromptPresets.all.first { $0.id == "builtin.key-points" })
        var prompts = [LLMPromptPreset(name: "要点清单", system: preset.system, user: preset.user,
                                       builtinID: preset.id, builtinVersion: preset.version)]
        let before = prompts
        BuiltinPromptPresets.syncImportedPresets(&prompts)
        BuiltinPromptPresets.syncImportedPresets(&prompts)
        XCTAssertEqual(prompts, before)
    }

    /// 无 builtinID 的用户自建预设不受浮动影响。
    func testPlainUserPresetsAreUntouched() {
        var prompts = [LLMPromptPreset(name: "自建", system: "x", user: "y")]
        let before = prompts
        BuiltinPromptPresets.syncImportedPresets(&prompts)
        XCTAssertEqual(prompts, before)
    }

    // MARK: - builtinID / builtinVersion 兼容

    /// 旧版 config.json 中的预设没有 builtinID/builtinVersion 字段：解码必须成功且为 nil。
    func testPresetWithoutBuiltinFieldsDecodesAsNil() throws {
        let json = """
        { "id": "p1", "name": "我的预设", "system": "s", "user": "u" }
        """
        let preset = try JSONDecoder().decode(LLMPromptPreset.self, from: Data(json.utf8))
        XCTAssertNil(preset.builtinID)
        XCTAssertNil(preset.builtinVersion)
        XCTAssertEqual(preset.name, "我的预设")
    }

    /// builtinID/builtinVersion 完整往返（导入标记持久化）。
    func testBuiltinFieldsRoundTrip() throws {
        let preset = LLMPromptPreset(name: "会议纪要", system: "s", user: "u",
                                     builtinID: "builtin.meeting-notes", builtinVersion: 1)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(LLMPromptPreset.self, from: data)
        XCTAssertEqual(decoded.builtinID, "builtin.meeting-notes")
        XCTAssertEqual(decoded.builtinVersion, 1)
    }
}

// MARK: - 默认提示词升级询问（一次性）

final class PromptUpgradeOfferTests: XCTestCase {

    private func repoResources() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoiceKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/VoiceKit/Resources")
    }

    /// 旧默认清单从 strings 加载：10 个语言一份不少，且含中文旧默认（zh-Hans 的译文即 key 本身）。
    func testLegacyLoaderReadsAllTenLanguages() {
        let legacy = LegacyFactoryPolishPrompt.legacySystems(resourcesDirectory: repoResources())
        XCTAssertEqual(legacy.count, 10)
        XCTAssertTrue(legacy.contains(LegacyFactoryPolishPrompt.legacyKey))
    }

    /// 仍在用旧出厂默认（任一语言）→ 应该询问；问过就不再问。
    func testShouldOfferOnlyForUntouchedLegacyDefault() {
        let legacy = LegacyFactoryPolishPrompt.legacySystems(resourcesDirectory: repoResources())
        var config = AppConfig()
        config.llm.prompt = LLMPromptConfig(system: legacy[0], user: "x")

        XCTAssertTrue(PromptUpgradeOffer.shouldOffer(config: config, alreadyOffered: false, legacySystems: legacy))
        XCTAssertFalse(PromptUpgradeOffer.shouldOffer(config: config, alreadyOffered: true, legacySystems: legacy))
    }

    /// 新默认 / 用户自定义过的提示词 → 不询问。
    func testNoOfferForNewDefaultOrCustomized() {
        let legacy = LegacyFactoryPolishPrompt.legacySystems(resourcesDirectory: repoResources())

        var fresh = AppConfig() // 新默认
        XCTAssertFalse(PromptUpgradeOffer.shouldOffer(config: fresh, alreadyOffered: false, legacySystems: legacy))

        fresh.llm.prompt = LLMPromptConfig(system: legacy[0] + "\n自定义一行", user: "x")
        XCTAssertFalse(PromptUpgradeOffer.shouldOffer(config: fresh, alreadyOffered: false, legacySystems: legacy))
    }
}
