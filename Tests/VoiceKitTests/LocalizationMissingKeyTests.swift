import XCTest

/// 本地化缺失 key 守护：源码中所有含 CJK 的字符串 literal 都必须作为 key
/// 存在于 zh-Hans.lproj/Localizable.strings（进而被 LocalizationKeyParityTests 强制同步到全部语言）。
///
/// 背景：key 为中文源串、fallback 为 key 本身。若某 UI 文案只写在代码里而未进 strings，
/// 非中文系统会静默显示中文（曾导致设置页「Data Privacy」等页面在英文系统下混着中文），
/// 且 parity 测试无法发现"所有语言都缺"的情况。此测试直接拦截这类遗漏。
final class LocalizationMissingKeyTests: XCTestCase {

    /// 由编译期文件路径推导仓库根目录（测试仅在开发/CI 环境运行，不随包分发）。
    private func repoRoot() -> URL {
        // .../Tests/VoiceKitTests/LocalizationMissingKeyTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func zhHansKeys() throws -> Set<String> {
        let url = repoRoot()
            .appendingPathComponent("Sources/VoiceKit/Resources/zh-Hans.lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: String] else {
            XCTFail("zh-Hans.lproj/Localizable.strings 解析结果不是字符串字典")
            return []
        }
        return Set(dict.keys)
    }

    /// 提取指定 Swift 文件中所有含 CJK 的字符串 literal（按源码原文做 Swift 转义还原）。
    /// 排除：注释行、Log. / print 日志行。
    private func cjkStringLiterals(in file: URL) throws -> [(literal: String, line: Int)] {
        let content = try String(contentsOf: file, encoding: .utf8)
        let pattern = #""((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var results: [(String, Int)] = []
        var inBlockComment = false

        for (index, rawLine) in content.components(separatedBy: "\n").enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if let end = line.range(of: "*/") {
                    line = String(line[end.upperBound...])
                    inBlockComment = false
                } else {
                    continue
                }
            }
            if line.hasPrefix("//") || line.hasPrefix("*") { continue }
            if line.hasPrefix("/*") {
                if line.range(of: "*/") == nil { inBlockComment = true }
                continue
            }
            // 日志/调试输出不参与本地化
            if line.contains("Log.") || line.contains("print(") { continue }

            let nsRange = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: nsRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                let literal = unescape(String(line[range]))
                if literal.unicodeScalars.contains(where: isCJK) {
                    results.append((literal, index + 1))
                }
            }
        }
        return results
    }

    private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)   // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(scalar.value)   // 扩展 A
            || (0x3000...0x303F).contains(scalar.value)   // CJK 标点
            || (0xFF00...0xFFEF).contains(scalar.value)   // 全角字符
    }

    /// 还原 Swift 字符串 literal 中的常见转义（未知转义如 \( 插值保持原样）。
    private func unescape(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\\", raw.index(after: i) < raw.endIndex {
                let next = raw[raw.index(after: i)]
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "0": result.append("\0")
                default:
                    result.append("\\")
                    result.append(next)
                }
                i = raw.index(i, offsetBy: 2)
            } else {
                result.append(raw[i])
                i = raw.index(after: i)
            }
        }
        return result
    }

    func testAllCJKStringLiteralsExistAsZhHansKeys() throws {
        let keys = try zhHansKeys()
        XCTAssertGreaterThan(keys.count, 100, "基线语言 key 数量异常，可能路径解析失败")

        let sourcesDir = repoRoot().appendingPathComponent("Sources/VoiceKit")
        let enumerator = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
        var swiftFiles: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "swift" { swiftFiles.append(file) }
        }
        XCTAssertFalse(swiftFiles.isEmpty, "未找到任何 Swift 源文件，可能路径解析失败")

        var missing: [String] = []
        for file in swiftFiles.sorted(by: { $0.path < $1.path }) {
            for (literal, line) in try cjkStringLiterals(in: file) where !keys.contains(literal) {
                let shortPath = file.path.replacingOccurrences(of: repoRoot().path + "/", with: "")
                missing.append("\(shortPath):\(line) → \(literal)")
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "以下含中文的字符串 literal 未加入 Localizable.strings（共 \(missing.count) 处）：\n"
                + missing.joined(separator: "\n")
        )
    }

    /// strings 文件内重复 key 守护：旧式 plist 解析对重复 key 静默取后者，
    /// 并发/追加编辑容易产生重复行且 parity 测试（Set 语义）无法发现。
    func testNoDuplicateKeysInAnyLanguage() throws {
        let resourcesDir = repoRoot().appendingPathComponent("Sources/VoiceKit/Resources")
        let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "pt-BR", "it"]
        let keyPattern = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#)

        for lang in languages {
            let url = resourcesDir.appendingPathComponent("\(lang).lproj/Localizable.strings")
            let content = try String(contentsOf: url, encoding: .utf8)
            var seen = Set<String>()
            var duplicates: [String] = []
            for rawLine in content.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let nsRange = NSRange(line.startIndex..., in: line)
                guard let match = keyPattern.firstMatch(in: line, range: nsRange),
                      let range = Range(match.range(at: 1), in: line) else { continue }
                let key = String(line[range])
                if !seen.insert(key).inserted { duplicates.append(key) }
            }
            XCTAssertTrue(duplicates.isEmpty, "\(lang).lproj 存在重复 key：\(duplicates)")
        }
    }
}
