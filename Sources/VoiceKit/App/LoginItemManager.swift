import Foundation
import ServiceManagement

/// 登录项管理：基于 SMAppService.mainApp（macOS 13+，VoiceKit 为非沙盒 agent，无需 Helper）。
enum LoginItemManager {
    /// 根据 enabled 注册/注销主 app 为登录项。返回 nil 成功，非 nil 为错误描述。
    @discardableResult
    static func set(enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return nil }
                try service.register()
                print("[LoginItem] registered mainApp as login item")
            } else {
                guard service.status == .enabled else { return nil }
                try service.unregister()
                print("[LoginItem] unregistered mainApp")
            }
            return nil
        } catch {
            print("[LoginItem] set(enabled:\(enabled)) failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
