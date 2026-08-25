import AppKit
import Foundation

/// 配置存储：全量写入应用支持目录下的 VoiceMate/config.json。
/// 官网版对应 ~/Library/Application Support；App Store 版对应其沙盒容器。
/// 为免去 Keychain 访问在开发/运行时反复弹密码的麻烦，API Key 直接以明文存于 config.json
/// （本地个人工具，风险可接受）。后续若需更高安全，可改回 Keychain。
///
/// 配置防御（读取侧恢复逻辑在 ConfigRecovery.swift，纯 Foundation 可单测）：
/// 1. 每次保存成功滚动写 config.backup.json（永远等于「上一次保存成功」的完好副本）
/// 2. 主文件损坏 → 自动从备份恢复并回写修复，Toast 告知
/// 3. 双份都损坏 → 坏文件改名 config.corrupt-<时间戳>.json 保留原地（绝不删除，
///    含明文 API Key），默认配置启动 + 弹窗提示
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    private let fileURL: URL
    private let backupURL: URL
    private var source: DispatchSourceFileSystemObject?
    private(set) var config: AppConfig
    /// 本次启动的恢复结果（用于 App 启动后补弹提示）
    private(set) var recoveryState: ConfigRecoveryState = .none

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("config.json")
        self.backupURL = support.appendingPathComponent("config.backup.json")
        let (loaded, recovery) = ConfigFileRecovery.load(fileURL: fileURL, backupURL: backupURL)
        self.config = loaded
        self.recoveryState = recovery
        print("[ConfigStore] config loaded, asr.engine=\(loaded.asr.engine), llm.models=\(loaded.llm.models.count), recovery=\(recovery)")
        HistoryStore.shared.maxCount = config.general.maxHistoryCount
        startWatching()
        presentRecoveryUIIfNeeded()
    }

    // MARK: - 读取 / 写入（直接落盘，不碰 Keychain）

    private static func decode(fileURL: URL) throws -> AppConfig {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Import a configuration selected by the user through an NSOpenPanel.
    /// The App Store build cannot silently read the direct-distribution path.
    func importConfig(from url: URL) throws {
        guard ConfigImportPolicy.isSupportedImportURL(url) else {
            throw ConfigImportError.unsupportedFile
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        var imported = try Self.decode(fileURL: url)
        imported.llm.migrateFromLegacy()
        update(imported)
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL, options: .atomic)
            // 配置防御第 1 层：保存成功后滚动写备份副本，备份失败不影响主流程
            try? data.write(to: backupURL, options: .atomic)
        } catch {
            print("[ConfigStore] 保存配置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 恢复提示（启动后补弹）

    /// 恢复发生在 init（启动早期），Toast/弹窗推迟到事件循环空闲时展示。
    private func presentRecoveryUIIfNeeded() {
        switch recoveryState {
        case .none:
            break
        case .restoredFromBackup:
            Task { @MainActor in
                ToastController.shared.show(VoiceKitLocalization.string("配置异常，已从备份恢复。"))
            }
        case .isolated(let corruptURL):
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = VoiceKitLocalization.string("配置文件已损坏")
                alert.informativeText = VoiceKitLocalization.string("已使用默认配置启动。损坏的原文件已保留在配置目录中，可交给 AI 助手协助修复。")
                alert.addButton(withTitle: VoiceKitLocalization.string("打开配置文件夹"))
                alert.addButton(withTitle: VoiceKitLocalization.string("好"))
                alert.alertStyle = .critical
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([corruptURL])
                }
            }
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
        // 云端引擎参数变更 → 下次重新创建（常驻连接需断开重建）
        if new.asr.engine != "system" {
            AppCoordinator.shared.invalidateASREngine()
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return loginItemErr
    }

    /// LLM 调用完成后累加 token 统计并自动落盘。
    func addLLMTokenUsage(modelID: String, tokens: Int) {
        guard let idx = config.llm.models.firstIndex(where: { $0.id == modelID }) else { return }
        config.llm.models[idx].totalTokens += tokens
        config.llm.models[idx].usageCount += 1
        save()
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
            // 重试 3 次仍无法读取（外部写入了坏 JSON / 文件被替换）：通知用户，不再静默放弃
            Task { @MainActor in
                print("[ConfigStore] 热重载失败：config.json 无法读取，保持当前配置")
                ToastController.shared.show(
                    VoiceKitLocalization.string("配置文件被外部修改但无法读取，已保持当前配置。")
                )
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
}

enum ConfigImportError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return VoiceKitLocalization.string("请选择官网版的 config.json 文件")
        }
    }
}
