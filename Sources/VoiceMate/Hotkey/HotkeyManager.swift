import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 全局热键管理：使用 Carbon 的 RegisterEventHotKey（无需辅助功能权限）。
/// 热键字符串形如 "Cmd+Shift+V"，可自定义并在设置中热切换。
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x564D5445 // 'VMTE'
    fileprivate let hotKeyIDValue: UInt32 = 1

    /// 热键触发回调（已调度到主线程）。
    var onActivate: (() -> Void)?

    // MARK: - 注册 / 注销

    /// 依据热键字符串（如 "Cmd+Shift+V"）注册；重复调用会先注销旧热键。
    func register(hotkeyString: String) {
        unregister()
        guard let (keyCode, modifiers) = Self.parse(hotkeyString) else {
            print("[HotkeyManager] 无法解析热键：\(hotkeyString)")
            return
        }
        installEventHandler()
        var hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            print("[HotkeyManager] RegisterEventHotKey 失败，状态码：\(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - 事件处理

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var types = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &types,
            selfPtr,
            &eventHandler
        )
    }

    // MARK: - 解析

    /// 解析 "Cmd+Shift+V" 之类字符串为 (keyCode, Carbon modifiers)。
    private static func parse(_ string: String) -> (UInt32, UInt32)? {
        let parts = string.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyPart = parts.last else { return nil }
        guard let keyCode = keyCodeMap[String(keyPart).uppercased()] else { return nil }

        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch String(part).lowercased() {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default: break
            }
        }
        return (keyCode, modifiers)
    }

    /// ANSI 键盘码（macOS kVK_ANSI_*）。仅列出常用字母/符号。
    private static let keyCodeMap: [String: UInt32] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05,
        "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09, "B": 0x0B,
        "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "I": 0x22, "O": 0x1F, "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28,
        "N": 0x2D, "M": 0x2E,
        "SPACE": 0x31,
    ]
}

// MARK: - C 回调（Carbon 要求函数指针）

private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ theEvent: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let theEvent else { return noErr }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    var hkID = EventHotKeyID()
    let status = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    if status == noErr, hkID.id == manager.hotKeyIDValue {
        // 趁热键事件刚送达、仍处于「用户事件」上下文：先把 agent 进程切为前台
        // （agent 应用无法被 NSApp.activate 激活），再立即激活到前台。延后(async)的
        // 激活会被系统以「非用户事件」忽略，导致面板不在最上层、听写 daemon 不回传结果。
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        _ = TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToForegroundApplication))
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        DispatchQueue.main.async { manager.onActivate?() }
    }
    return noErr
}
