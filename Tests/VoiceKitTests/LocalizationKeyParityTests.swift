import XCTest

/// 本地化一致性守护：10 种语言的 Localizable.strings 必须拥有完全一致的 key 集合。
///
/// 背景：key 为中文源串，某语言文件里 key 打错一个字符只会导致该语言静默回退显示中文，
/// 运行期无任何报错。此测试在 CI/本地跑测试时直接拦截这类漂移。
final class LocalizationKeyParityTests: XCTestCase {
    private static let languages = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "pt-BR", "it"
    ]

    /// 由编译期文件路径推导仓库根目录（测试仅在开发/CI 环境运行，不随包分发）。
    private func resourcesDirectory() -> URL {
        // .../Tests/VoiceKitTests/LocalizationKeyParityTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceKit/Resources")
    }

    private func keys(for language: String) throws -> Set<String> {
        let url = resourcesDirectory().appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: String] else {
            XCTFail("\(language).lproj/Localizable.strings 解析结果不是字符串字典")
            return []
        }
        return Set(dict.keys)
    }

    func testAllLanguagesShareIdenticalKeySets() throws {
        let baseline = "zh-Hans"
        let baselineKeys = try keys(for: baseline)
        XCTAssertGreaterThan(baselineKeys.count, 100, "基线语言 key 数量异常，可能路径解析失败")

        for lang in Self.languages where lang != baseline {
            let other = try keys(for: lang)
            let missing = baselineKeys.subtracting(other).sorted()
            let extra = other.subtracting(baselineKeys).sorted()
            XCTAssertTrue(
                missing.isEmpty && extra.isEmpty,
                "\(lang) 与 \(baseline) key 集合不一致：缺失 \(missing.prefix(10))，多余 \(extra.prefix(10))"
            )
        }
    }
}
