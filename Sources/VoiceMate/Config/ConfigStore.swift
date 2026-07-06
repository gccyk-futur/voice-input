import Foundation

/// 配置存储：全量写入 ~/Library/Application Support/VoiceMate/config.json，
/// 敏感字段落盘脱敏为 "****" 并写入 Keychain；支持外部修改文件后热重载。
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileURL: URL
    private let keychain: KeychainStore
    private let secretKeys: [String] = [
        "llm.openai.apiKey",
        "llm.deepseek.apiKey",
        "llm.claude.apiKey",
        "llm.custom.apiKey",
        "asr.iflytek.apiKey",
        "asr.aliyun.accessKey",
        "asr.aliyun.accessSecret",
        "asr.openaiWhisper.apiKey"
    ]
    private(set) var config: AppConfig
    private var source: DispatchSourceFileSystemEvent?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("config.json")
        self.keychain = KeychainStore(service: "com.voicemate.VoiceMate")
        self.config = ConfigStore.read(fileURL: fileURL, keychain: keychain)
        startWatching()
    }

    // MARK: - 读取（从文件 + Keychain 还原敏感字段）

    static func read(fileURL: URL, keychain: KeychainStore) -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        var c = decoded
        if let v = keychain.get("llm.openai.apiKey"), !v.isEmpty { c.llm.openai.apiKey = v }
        if let v = keychain.get("llm.deepseek.apiKey"), !v.isEmpty { c.llm.deepseek.apiKey = v }
        if let v = keychain.get("llm.claude.apiKey"), !v.isEmpty { c.llm.claude.apiKey = v }
        if let v = keychain.get("llm.custom.apiKey"), !v.isEmpty { c.llm.custom.apiKey = v }
        if let v = keychain.get("asr.iflytek.apiKey"), !v.isEmpty { c.asr.iflytek.apiKey = v }
        if let v = keychain.get("asr.aliyun.accessKey"), !v.isEmpty { c.asr.aliyun.accessKey = v }
        if let v = keychain.get("asr.aliyun.accessSecret"), !v.isEmpty { c.asr.aliyun.accessSecret = v }
        if let v = keychain.get("asr.openaiWhisper.apiKey"), !v.isEmpty { c.asr.openaiWhisper.apiKey = v }
        return c
    }

    // MARK: - 写入（敏感字段存 Keychain，文件脱敏）

    func save() {
        var c = config
        keychain.set(c.llm.openai.apiKey, forKey: "llm.openai.apiKey")
        keychain.set(c.llm.deepseek.apiKey, forKey: "llm.deepseek.apiKey")
        keychain.set(c.llm.claude.apiKey, forKey: "llm.claude.apiKey")
        keychain.set(c.llm.custom.apiKey, forKey: "llm.custom.apiKey")
        keychain.set(c.asr.iflytek.apiKey, forKey: "asr.iflytek.apiKey")
        keychain.set(c.asr.aliyun.accessKey, forKey: "asr.aliyun.accessKey")
        keychain.set(c.asr.aliyun.accessSecret, forKey: "asr.aliyun.accessSecret")
        keychain.set(c.asr.openaiWhisper.apiKey, forKey: "asr.openaiWhisper.apiKey")

        c.llm.openai.apiKey = "****"
        c.llm.deepseek.apiKey = "****"
        c.llm.claude.apiKey = "****"
        c.llm.custom.apiKey = "****"
        c.asr.iflytek.apiKey = "****"
        c.asr.aliyun.accessKey = "****"
        c.asr.aliyun.accessSecret = "****"
        c.asr.openaiWhisper.apiKey = "****"

        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 用新配置覆盖并持久化（敏感字段写入 Keychain，文件脱敏）。
    func update(_ new: AppConfig) {
        config = new
        save()
    }

    func resetToDefaults() {
        config = AppConfig()
        for key in secretKeys { keychain.delete(key) }
        save()
    }

    // MARK: - 热重载

    private func startWatching() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd != -1 else { return }
        let src = DispatchSource.makeFileSystemSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.config = ConfigStore.read(fileURL: self.fileURL, keychain: self.keychain)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        self.source = src
    }
}
