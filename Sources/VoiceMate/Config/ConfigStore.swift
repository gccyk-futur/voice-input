import Foundation

/// 配置存储：全量写入 ~/Library/Application Support/VoiceMate/config.json。
/// 为免去 Keychain 访问在开发/运行时反复弹密码的麻烦，API Key 直接以明文存于 config.json
/// （本地个人工具，风险可接受）。后续若需更高安全，可改回 Keychain。
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileURL: URL
    private var source: DispatchSourceFileSystemObject?
    private(set) var config: AppConfig

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("config.json")
        self.config = ConfigStore.read(fileURL: fileURL)
        startWatching()
    }

    // MARK: - 读取 / 写入（直接落盘，不碰 Keychain）

    static func read(fileURL: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            print("[ConfigStore] 读取 config.json 失败，使用默认配置")
            return AppConfig()
        }
        print("[ConfigStore] config loaded, asr.engine=\(decoded.asr.engine)")
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 用新配置覆盖并持久化；同时同步登录项开关。
    func update(_ new: AppConfig) {
        config = new
        save()
        LoginItemManager.set(enabled: new.general.launchAtStartup)
    }

    func resetToDefaults() {
        config = AppConfig()
        save()
    }

    // MARK: - 热重载

    private func startWatching() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd != -1 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.config = ConfigStore.read(fileURL: self.fileURL)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        self.source = src
    }
}
