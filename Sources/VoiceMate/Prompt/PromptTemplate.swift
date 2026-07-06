import Foundation

/// Prompt 变量替换：支持 {{input}} {{language}} {{engine}} {{timestamp}} {{custom.xxx}}。
struct PromptTemplate {
    var system: String
    var user: String

    func render(input: String, language: String, engine: String, custom: [String: String] = [:]) -> (system: String, user: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let variables: [String: String] = [
            "{{input}}": input,
            "{{language}}": language,
            "{{engine}}": engine,
            "{{timestamp}}": timestamp
        ]
        var sys = system
        var usr = user
        for (key, value) in variables {
            sys = sys.replacingOccurrences(of: key, with: value)
            usr = usr.replacingOccurrences(of: key, with: value)
        }
        for (key, value) in custom {
            usr = usr.replacingOccurrences(of: "{{custom.\(key)}}", with: value)
        }
        return (sys, usr)
    }
}
