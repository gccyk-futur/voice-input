import Foundation

/// 启动读取配置时的恢复结果（配置防御）。
enum ConfigRecoveryState: Equatable {
    /// 主配置正常，或首次启动尚无文件
    case none
    /// 主配置损坏，已从 config.backup.json 恢复（并回写修复主文件）
    case restoredFromBackup
    /// 主配置与备份都损坏：坏文件已隔离保留，使用默认配置启动
    case isolated(corruptURL: URL)
}

/// 损坏文件隔离器：改名保留现场，绝不删除（里面可能有用户的 API Key / 历史数据）。
enum CorruptFileIsolator {
    /// 将 url 改名为 `<name>.corrupt-<yyyyMMdd-HHmmss>.<ext>`，返回新路径。
    /// 文件不存在或改名失败时返回 nil。
    @discardableResult
    static func isolate(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(base).corrupt-\(stamp)" : "\(base).corrupt-\(stamp).\(ext)"
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fm.moveItem(at: url, to: dest)
            return dest
        } catch {
            print("[CorruptFileIsolator] 隔离失败 \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}

/// 配置读取的恢复逻辑（纯 Foundation，供单测覆盖；UI 提示由 ConfigStore 负责）。
///
/// 三层防御的读取侧：
/// 1. 主文件正常 → 直接用
/// 2. 主文件损坏 → 尝试 config.backup.json（每次保存成功时滚动写入的完好副本），
///    成功则回写修复主文件
/// 3. 双份都损坏 → 隔离保现场，默认配置启动
enum ConfigFileRecovery {
    static func load(fileURL: URL, backupURL: URL) -> (config: AppConfig, state: ConfigRecoveryState) {
        // 文件不存在（首次启动）不算损坏
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return (AppConfig(), .none)
        }

        if var decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            decoded.llm.migrateFromLegacy()
            return (decoded, .none)
        }

        // 主文件损坏：尝试备份
        if let backupData = try? Data(contentsOf: backupURL),
           var decoded = try? JSONDecoder().decode(AppConfig.self, from: backupData) {
            decoded.llm.migrateFromLegacy()
            // 回写修复主文件，下次启动不再依赖备份
            try? backupData.write(to: fileURL, options: .atomic)
            print("[ConfigStore] config.json 损坏，已从备份恢复")
            return (decoded, .restoredFromBackup)
        }

        // 双份都坏：隔离保现场（坏文件里可能有明文 API Key，绝不删除）
        CorruptFileIsolator.isolate(backupURL)
        let corruptURL = CorruptFileIsolator.isolate(fileURL) ?? fileURL
        print("[ConfigStore] config.json 与备份均损坏，已隔离并使用默认配置")
        return (AppConfig(), .isolated(corruptURL: corruptURL))
    }
}
