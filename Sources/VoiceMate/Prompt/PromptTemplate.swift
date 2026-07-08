import Foundation

/// Prompt 变量替换：支持 {{input}} {{language}} {{engine}} {{timestamp}} {{custom.xxx}}。
struct PromptTemplate {
    var system: String
    var user: String

    func render(input: String, language: String, engine: String, custom: [String: String] = [:]) -> (system: String, user: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // 先替换非 input 变量（language, engine, timestamp, custom.*），
        // 最后替换 {{input}}，确保 input 内容不会被后续替换误改。
        let metaVariables: [String: String] = [
            "{{language}}": language,
            "{{engine}}": engine,
            "{{timestamp}}": timestamp
        ]
        var sys = system
        var usr = user
        for (key, value) in metaVariables {
            sys = sys.replacingOccurrences(of: key, with: value)
            usr = usr.replacingOccurrences(of: key, with: value)
        }
        for (key, value) in custom {
            usr = usr.replacingOccurrences(of: "{{custom.\(key)}}", with: value)
        }
        // {{input}} 最后替换，避免 input 内容中的 {{…}} 被二次替换
        sys = sys.replacingOccurrences(of: "{{input}}", with: input)
        usr = usr.replacingOccurrences(of: "{{input}}", with: input)
        return (sys, usr)
    }
}
