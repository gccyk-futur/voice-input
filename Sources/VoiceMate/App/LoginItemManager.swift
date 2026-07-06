import Foundation
import ServiceManagement

/// 登录项管理：基于 SMAppService.mainApp（macOS 13+，VoiceMate 为非沙盒 agent，无需 Helper）。
enum LoginItemManager {
    /// 根据 enabled 注册/注销主 app 为登录项。失败仅打印（如系统授权弹窗被拒）。
    static func set(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
                print("[LoginItem] registered mainApp as login item")
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
                print("[LoginItem] unregistered mainApp")
            }
        } catch {
            print("[LoginItem] set(enabled:\(enabled)) failed: \(error.localizedDescription)")
        }
    }
}
