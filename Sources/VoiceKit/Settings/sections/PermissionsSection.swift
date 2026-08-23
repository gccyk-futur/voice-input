import SwiftUI
import AVFoundation
import Speech
import AppKit
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - 权限（自 SettingsView.swift 机械拆出，逻辑未改动）

extension SettingsView {
    var permissionTab: some View {
        Group {
            Section {
                permissionRow(
                    icon: "mic.fill",
                    name: "麦克风",
                    why: "听到你的声音，才能转成文字",
                    ifDenied: "不授权：无法使用语音输入",
                    status: micStatus,
                    action: requestMicPermission
                )
            }

            Section {
                permissionRow(
                    icon: "text.bubble.fill",
                    name: "语音识别",
                    why: "把你说的话实时转写成文字",
                    ifDenied: "不授权：无法使用语音输入",
                    status: speechStatus,
                    action: requestSpeechPermission
                )
            }

            // 辅助功能（仅官网版）。App Store 版不展示任何辅助功能/键盘事件
            // 引导行（Guideline 2.4.5：1.1.0 因主动请求键盘事件权限被拒审，
            // 复审会盯此页）；沙盒版只做静默 preflight，用户在系统设置中
            // 手动勾选后自动写回自然生效，无需 App 引导。
#if !APP_STORE
            Section {
                permissionRow(
                    icon: "rectangle.and.hand.point.up.left.fill",
                    name: "辅助功能（直接写入）",
                    why: "允许 VoiceKit 直接访问目标输入框写入文字",
                    ifDenied: "不授权：会回退到剪贴板，请手动按 ⌘V",
                    status: accessibilityStatus,
                    action: requestAccessibilityPermission
                )
            }
#endif

            // 重启提示（两版通用：辅助功能/键盘事件授权后，TCC 进程级缓存需重启刷新）
            if case .recommended = restartState {
                Section {
                    restartRow
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("权限状态会在返回 VoiceKit 时刷新", systemImage: "arrow.triangle.2.circlepath")
                        .font(typography.callout).foregroundStyle(.secondary)
                    Text(permissionReloadHint)
                        .font(typography.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

#if !APP_STORE
                    Label("多个 VoiceKit 副本", systemImage: "doc.on.doc")
                        .font(typography.callout).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("如果你安装过多个版本的 VoiceKit（比如从官网下载的 DMG 和从 App Store 下载的版本），每个版本需要单独授权。它们是 macOS 眼中的「不同 App」。")
                        .font(typography.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
#endif
                }
                .padding(.vertical, 4)
            } header: {
                Text("说明")
            }
        }
        // 从系统设置返回 App 时刷新权限状态，保证授权结果立即反映到界面
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshID = UUID()
        }
    }

    // MARK: - 数据隐私

    var micStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    var speechStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    var distribution: VoiceKitDistribution {
#if APP_STORE
        .appStore
#else
        .direct
#endif
    }

    var permissionReloadHint: String {
#if APP_STORE
            return VoiceKitLocalization.string("麦克风和语音识别授权后立即生效；键盘事件权限在系统设置中授权后，需要重启 VoiceKit 才会生效。")
#else
        if case .recommended = restartState {
            return VoiceKitLocalization.string("辅助功能刚授权，请使用上方的重启按钮；麦克风和语音识别权限通常不需要重启。")
        }
        return VoiceKitLocalization.string("只有辅助功能在刚授权后可能需要重启；麦克风和语音识别权限通常不需要重启。")
#endif
    }

    /// 未决定时触发系统授权弹窗（App Review 5.1.1(iv)：按钮用「继续」而非「去授权」）；
    /// 已被拒绝时系统弹窗不会再出现，改为打开对应系统设置页。
    /// 必须 Task.detached：权限回调在后台线程（TCC XPC 回复队列）触发，
    /// 闭包若从 View 继承 MainActor 隔离，会触发 swift_task_checkIsolatedSwift
    /// 断言崩溃（EXC_BAD_INSTRUCTION，Release 同样崩）。
    func requestMicPermission() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            PasteService.shared.openMicrophoneSettings()
            return
        }
        Task.detached {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            await MainActor.run { permissionRefreshID = UUID() }
        }
    }

    func requestSpeechPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            PasteService.shared.openSpeechSettings()
            return
        }
        Task.detached {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            await MainActor.run { permissionRefreshID = UUID() }
        }
    }

#if !APP_STORE
    var accessibilityStatus: VoiceKitPermissionState {
        _ = permissionRefreshID
        // 只信 AXIsProcessTrusted：曾经用「读取系统焦点元素」做兜底探测，
        // 但 App 查看自己的设置页时 VoiceKit 必定是前台 App，
        // 而读取自身 AX 树不需要辅助功能授权 → 探测恒成功，误报「已授权」。
        // 注意：AXIsProcessTrusted 的结果是进程级缓存，授权/撤销后需重启 App 才会刷新，
        // 这正是下方 restartRow 提示存在的原因。
        if PasteService.shared.isTrusted { return .granted }
        return .notDetermined
    }

    /// 辅助功能没有异步授权 API：AXIsProcessTrustedWithOptions(prompt: true)
    /// 会弹出系统授权提示，并把 App 自动加入辅助功能列表（默认未勾选），
    /// 用户勾选后生效。授权结果不回调，靠 didBecomeActiveNotification 刷新状态。
    func requestAccessibilityPermission() {
        guard !PasteService.shared.isTrusted else { return }
        restartRequested = true
        // kAXTrustedCheckOptionPrompt 是可变全局变量，Swift 6 并发检查不允许直接引用；
        // 该 key 字符串是稳定 API，直接使用字面量。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
#endif

    var restartState: VoiceKitPermissionReloadState {
        VoiceKitPermissionReloadState.make(
            distribution: distribution,
            accessibility: currentAccessibilityStatus,
            accessibilityRequested: restartRequested,
            postEventRequested: postEventRequestAttempted,
            postEventUsable: PasteService.shared.canPostEvents,
            postEventDismissed: postEventRestartDismissed
        )
    }

    /// App Store 版没有辅助功能路径，状态机里占位（不参与判定）。
    var currentAccessibilityStatus: VoiceKitPermissionState {
#if APP_STORE
        .notDetermined
#else
        accessibilityStatus
#endif
    }

    func permissionRow(icon: String, name: String, why: String, ifDenied: String, status: VoiceKitPermissionState, action: @escaping () -> Void) -> some View {
        let localizedName = VoiceKitLocalization.string(name)
        let localizedWhy = VoiceKitLocalization.string(why)
        let localizedIfDenied = VoiceKitLocalization.string(ifDenied)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(status == .granted ? VoiceKitSemanticColor.success : VoiceKitSemanticColor.secondaryText)
                    .frame(width: 24)
                Text(localizedName).font(typography.body).bold()
                Spacer()
                statusBadge(status)
                if status != .granted {
                    // App Review 5.1.1(iv)：授权弹窗前的按钮用「继续」这类中性文案；
                    // 已被拒绝时按钮的作用是跳转系统设置，如实标注。
                    Button(status == .notDetermined
                           ? VoiceKitLocalization.string("继续")
                           : VoiceKitLocalization.string("打开系统设置")) { action() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(localizedWhy)
                .font(typography.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status != .granted {
                Text(localizedIfDenied)
                    .font(typography.callout).foregroundStyle(VoiceKitSemanticColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    func statusBadge(_ status: VoiceKitPermissionState) -> some View {
        switch status {
        case .granted:
            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(VoiceKitSemanticColor.success).font(typography.callout)
        case .denied:
            Label("已拒绝", systemImage: "xmark.circle.fill").foregroundStyle(VoiceKitSemanticColor.failure).font(typography.callout)
        case .notDetermined:
            Label("未授权", systemImage: "questionmark.circle").foregroundStyle(VoiceKitSemanticColor.warning).font(typography.callout)
        }
    }

    var restartRow: some View {
        let copy: (title: String, detail: String) = {
            if case .recommended(.postEvent) = restartState {
                return (
                    VoiceKitLocalization.string("自动写回将在重启后生效"),
                    VoiceKitLocalization.string("如果你刚刚在系统提示或系统设置中允许了键盘事件权限，VoiceKit 需要重启一次才能识别到新授权（系统缓存限制）。")
                )
            }
            return (
                VoiceKitLocalization.string("辅助功能已授权"),
                VoiceKitLocalization.string("重启 VoiceKit，让刚授权的直接写入能力完整生效。")
            )
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.title)
                    .font(typography.sectionTitle)
                Text(copy.detail)
                    .font(typography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(VoiceKitLocalization.string("现在重启 VoiceKit")) {
                        restartApplication()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(VoiceKitLocalization.string("稍后处理")) {
                        dismissRestartRow()
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

}
