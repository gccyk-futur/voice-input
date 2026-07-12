import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 全局热键管理：双引擎自动切换。
///
/// - 非沙盒环境：Carbon RegisterEventHotKey（零权限，静默注册）
/// - 沙盒环境（App Store）：自动回退到 NSEvent Global Monitor（需辅助功能权限）
///
/// 两者对外接口完全一致，调用方无需感知底层实现。
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    // Carbon 引擎
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x564D5445 // 'VMTE'
    fileprivate let hotKeyIDValue: UInt32 = 1

    // NSEvent Global Monitor 引擎（沙盒回退）
    private var globalMonitor: Any?

    /// 当前活跃的引擎类型
    private enum Engine { case carbon, globalMonitor }
    private var activeEngine: Engine = .carbon

    /// 热键触发回调（已调度到主线程）。
    var onActivate: (() -> Void)?
    /// 热键触发瞬间的前台 app（回调里捕获，传给 AppCoordinator 作为粘贴目标）。
    nonisolated(unsafe) var capturedTargetApp: NSRunningApplication?
    /// 上次触发时间：用于过滤按键自动重复（auto-repeat）造成的二次触发。
    fileprivate var lastActivation: Date = .distantPast
    /// 当前热键字符串，供 Global Monitor 匹配用
    private var currentHotkeyString: String = ""

    // MARK: - 注册 / 注销

    /// 依据热键字符串（如 "Cmd+Shift+V"）注册；重复调用会先注销旧热键。
    func register(hotkeyString: String) {
        unregister()
        currentHotkeyString = hotkeyString
        guard let (keyCode, modifiers) = Self.parse(hotkeyString) else {
            print("[HotkeyManager] 无法解析热键：\(hotkeyString)")
            return
        }

        // 策略 1：尝试 Carbon RegisterEventHotKey（零权限，首选）
        installCarbonHandler()
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            activeEngine = .carbon
            print("[HotkeyManager] Carbon 热键注册成功: \(hotkeyString)")
            return
        }

        // 策略 2：Carbon 失败（沙盒环境）→ 回退 NSEvent Global Monitor
        print("[HotkeyManager] Carbon 注册失败 (status=\(status))，回退 Global Monitor: \(hotkeyString)")
        activeEngine = .globalMonitor
        installGlobalMonitor(keyCode: keyCode, modifiers: modifiers, hotkeyString: hotkeyString)
    }

    func unregister() {
        // 注销 Carbon
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        // 注销 Global Monitor
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    // MARK: - Carbon 事件处理

    private func installCarbonHandler() {
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

    // MARK: - NSEvent Global Monitor（沙盒回退）

    /// 使用 NSEvent.addGlobalMonitorForEvents 捕获全局按键。
    /// 需要辅助功能权限（AccessibilityPasteService 已引导用户授权）。
    private func installGlobalMonitor(keyCode: UInt32, modifiers: UInt32, hotkeyString: String) {
        let targetModifiers = Self.nseventModifiers(from: modifiers)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // 仅匹配 keyDown（忽略 auto-repeat：重复触发冷却由 lastActivation 统一处理）
            guard !event.isARepeat else { return }

            // 匹配修饰键 + 键码
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard eventMods == targetModifiers, event.keyCode == UInt16(keyCode) else { return }

            // 捕获前台 App（与 Carbon 路径行为一致）
            self.capturedTargetApp = NSWorkspace.shared.frontmostApplication
            print("[Hotkey] captured targetApp=\(self.capturedTargetApp?.localizedName ?? "nil")")

            DispatchQueue.main.async {
                let now = Date()
                if now.timeIntervalSince(self.lastActivation) < 0.4 {
                    print("[Hotkey] 忽略重复触发（auto-repeat 冷却中）")
                    return
                }
                self.lastActivation = now
                self.onActivate?()
            }
        }
        print("[HotkeyManager] Global Monitor 注册成功: \(hotkeyString)")
    }

    /// 将 Carbon modifiers 转换为 NSEvent.ModifierFlags。
    private static func nseventModifiers(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    // MARK: - 解析

    /// 解析 "Cmd+Shift+V" 之类字符串为 (keyCode, Carbon modifiers)。
    private static func parse(_ string: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = string.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }
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

    /// 反向：由 (keyCode, Carbon modifiers) 生成可存储的 "Cmd+Shift+V" 字符串（供录制 UI 使用）。
    /// 纯计算、不触达 actor 状态，故标 nonisolated 以便从事件回调线程调用。
    nonisolated static func format(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if let name = keyCodeMap.first(where: { $0.value == keyCode })?.key {
            parts.append(name)
        }
        return parts.joined(separator: "+")
    }

    /// 键盘码 -> 配置字符串名（字母/数字/符号 + 功能键 + 方向/删除等常用键）。
    private nonisolated static let keyCodeMap: [String: UInt32] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05,
        "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09, "B": 0x0B,
        "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "I": 0x22, "O": 0x1F, "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28,
        "N": 0x2D, "M": 0x2E,
        "SPACE": 0x31,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76,
        "F5": 0x60, "F6": 0x61, "F7": 0x62, "F8": 0x64,
        "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "UP": 0x7E, "DOWN": 0x7D, "LEFT": 0x7B, "RIGHT": 0x7C,
        "RETURN": 0x24, "ESCAPE": 0x35, "TAB": 0x30,
        "DELETE": 0x33, "FORWARDDELETE": 0x75,
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
        manager.capturedTargetApp = NSWorkspace.shared.frontmostApplication
        print("[Hotkey] captured targetApp=\(manager.capturedTargetApp?.localizedName ?? "nil")")
        DispatchQueue.main.async {
            let now = Date()
            if now.timeIntervalSince(manager.lastActivation) < 0.4 {
                print("[Hotkey] 忽略重复触发（auto-repeat 冷却中）")
                return
            }
            manager.lastActivation = now
            manager.onActivate?()
        }
    }
    return noErr
}
