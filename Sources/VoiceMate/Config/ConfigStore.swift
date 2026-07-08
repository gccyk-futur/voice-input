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
        HistoryStore.shared.maxCount = config.general.maxHistoryCount
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
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ConfigStore] 保存配置失败: \(error.localizedDescription)")
        }
    }

    /// 用新配置覆盖并持久化；同时同步登录项开关。
    /// 配置变更通知（StatusBarMenu 等监听刷新）。
    /// - Returns: 非 nil 表示登录项注册有错误，调用方可展示给用户。
    static let didChange = Notification.Name("VoiceMateConfigDidChange")

    @discardableResult
    func update(_ new: AppConfig) -> String? {
        config = new
        save()
        let loginItemErr = LoginItemManager.set(enabled: new.general.launchAtStartup)
        HistoryStore.shared.maxCount = new.general.maxHistoryCount
        // 阿里云引擎参数变更 → 下次重新创建
        if new.asr.engine == "aliyun" {
            AppCoordinator.shared.invalidateASREngine()
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return loginItemErr
    }

    func resetToDefaults() {
        config = AppConfig()
        save()
    }

    // MARK: - 热重载

    /// 后台队列：热重载重试逻辑不阻塞主线程。
    private let reloadQueue = DispatchQueue(label: "com.voicemate.config.reload", qos: .background)

    private func startWatching() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd != -1 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: reloadQueue
        )
        // 通过 nonisolated static 方法脱离 @MainActor 上下文，
        // 避免 macOS 26 严格并发检查在后台队列上触发 actor isolation 断言
        Self.setupFileWatch(source: src, url: fileURL, fd: fd)
        self.source = src
    }

    /// nonisolated static：脱离 @MainActor 上下文，禁止捕获 self，
    /// 只通过 ConfigStore.shared 单向更新主线程配置。
    private nonisolated static func setupFileWatch(
        source: DispatchSourceFileSystemObject,
        url: URL,
        fd: Int32
    ) {
        source.setEventHandler {
            for _ in 0..<3 {
                if let data = try? Data(contentsOf: url),
                   let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
                    Task { @MainActor in
                        ConfigStore.shared.config = decoded
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
}
