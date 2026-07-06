# VoiceMate 开发交接备忘录

> 更新：2026-07-07
> 状态：核心功能可用，粘贴正常，识别自动启动（多数app）

---

## 1. 项目概述

- **VoiceMate**：macOS 语音输入 app。全局热键 `⌘⇧V` 唤起 → 说话 →（可选 LLM 润色）→ 自动把文字插入当前光标位置。
- 技术栈：Swift 6、SwiftUI、XcodeGen（`project.yml`）、部署目标 macOS 26.0、架构 `arm64 x86_64`。
- 入口/中枢：`Sources/VoiceMate/Coordinator/AppCoordinator.swift`（`@MainActor @Observable`，状态机）。
- 构建：`xcodebuild -scheme VoiceMate -configuration Debug build`。

---

## 2. 架构

| 文件 | 职责 |
|---|---|
| `Coordinator/AppCoordinator.swift` | 状态机 `idle→recording→transcribing→polishing→ready`；驱动各服务；`enterForeground/exitForeground`；激活持久化；粘贴调度。 |
| `ASR/SystemDictationEngine.swift` | 主力引擎：`SpeechAnalyzer` + `DictationTranscriber`。**基于 CMTimeRange 的时间轴分段数组**做文本累计。 |
| `ASR/LegacyDictationEngine.swift` | 回退引擎：`SFSpeechRecognizer`。仅当系统听写不可用时使用。 |
| `Paste/PasteService.swift` | 粘贴：优先 AX 直插光标；回退写剪贴板 + HID ⌘V + pid 直送双通道。 |
| `Panel/FloatingPanelController.swift` | `NSPanel`（`.popUpMenu` 级别、`canJoinAllSpaces`）。`clickToActivate()` 是核心创新（见 §4）。 |
| `Hotkey/HotkeyManager.swift` | Carbon `RegisterEventHotKey` 全局热键；回调中捕获 `targetApp` + `TransformProcessType`。 |
| `LLM/*` | Ollama / OpenAI / DeepSeek 润色。 |

---

## 3. 状态机

```
idle --(⌘⇧V)--> recording --(⌘⇧V)--> transcribing --(结束)--> [polishing]? --> ready --(自动)--> confirmPaste --> reset --> idle
```

- `toggleRecording`：`idle→startRecording`，`recording→stopAndProcess`，其余状态 `break`。
- `confirmPaste` 无论成败都 `reset()`（否则卡 `.ready`）。
- `finalizing` 标志：自动粘贴期间屏蔽面板关闭触发的 `cancel`。

---

## 4. 核心修复：激活链路（为什么不需要点击面板了）

**问题**：DictationTranscriber 硬性要求 app 通过 WindowServer 级别的用户交互激活。`NSApp.activate` 发送 AppleEvent 请求，CPU 级 app（LSUIElement）发出的请求被 WindowServer 忽略。

**方案**：`FloatingPanelController.clickToActivate()` —— 向本进程 PID 发送模拟鼠标左键点击事件（`CGEvent.postToPid`）。AppKit 的 `NSWindow.sendEvent` 内部检测到鼠标点击 → 自动触发激活 → WindowServer 认可（与用户手动点击面板完全相同的代码路径）。

**完整链路**：
```
Carbon 热键回调
  ├─ capturedTargetApp（一切操作之前捕获）
  ├─ TransformProcessType（显示 Dock，使进程可被 WindowServer 激活）
  └─ DispatchQueue.main.async:
       ├─ setActivationPolicy(.regular) + NSApp.activate
       └─ onActivate → startRecording:
            ├─ enterForeground（兜底 TransformProcessType + setActivationPolicy）
            ├─ panel.show()
            ├─ panel.clickToActivate()          ← 核心：模拟点击
            ├─ scheduleActivationPersistence()  ← 0.08/0.20/0.35/0.55s 重新 click（对抗 iTerm2 焦点抢夺）
            └─ waitForActivation（轮询 isActive，只触发一次引擎启动）
                 └─ panel.orderFront()（激活后重新置顶 + makeKey）
```

**激活持久化**：某些 app（如 iTerm2）失去焦点后会立即 reclaim 激活。`scheduleActivationPersistence` 在 0.08/0.20/0.35/0.55s 重新发送 `clickToActivate`，确保 DictationTranscriber 初始化期间 VoiceMate 保持激活。

---

## 5. 文本累计：CMTimeRange 分段数组

`SystemDictationEngine` 使用基于时间轴的分段数组替代文本前缀判定：

- `DictationTranscriber.Result` 有三个关键属性：`range: CMTimeRange`、`text: AttributedString`、`resultsFinalizationTime: CMTime`
- 维护 `[Segment]` 有序数组（按 `range.start` 排序）
- 新 result 到来时按 `range` 查找重叠分段 → 原地更新文本；无重叠则有序插入新分段
- 已定稿分段不会被未定稿 result 覆盖（防止倒退）
- 显示文本 = `committed`（已定稿分段按时间拼接）+ `pending`（当前流式分段）
- 拉丁字母/数字之间自动加空格，CJK 直接相连

这解决了旧的文本前缀判定法的全部边缘 bug（整句重复、停顿清空、迟到重复）。

---

## 6. 粘贴：AX + HID + PID 三通道

`PasteService.paste(_:to:)` 的优先级：

1. **AX 直插**（`insertViaAccessibility`）— 需辅助功能权限。通过 `kAXSelectedTextAttribute` 在系统光标处插入，最可靠。
2. **HID ⌘V**（`simulateCmdV`）— 向 HID 级别投递 Cmd+V，走完整系统事件链。
3. **PID 直送**（`simulateCmdV(to:)`）— 向目标进程 PID 发送 Cmd+V 事件，无需目标在前台。

粘贴前通过 `waitForTargetActivation` 轮询确认目标 app 已回到前台（最长 0.6s），然后延迟 0.3s 等待文本框获焦，再执行粘贴。

**辅助功能权限**：必须用 Xcode Run（Automatic 签名，identity 稳定）运行，然后到 系统设置→隐私与安全性→辅助功能 授权。Ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）每次构建 identity 变化，授权不匹配。

---

## 7. 已知限制

- **Dock 图标在听写期间短暂显示**：`TransformProcessType` 的副作用，听写结束后 `exitForeground` 隐藏。这是 macOS 安全模型的设计限制（CPU 级 app 不能成为前台）。
- **`throwing -10877` + locale 警告**：DictationTranscriber 加载本地模型时的非致命日志。首次调用有约 1 秒冷启动延迟。
- **iTerm2 等终端 app**：有激活持久化对抗，但极端情况下可能仍不稳定。终端模拟器的焦点 reclaim 机制较强。

---

## 8. 测试清单

1. Xcode Run（⌘R）启动，确认 AX 权限 `isTrusted=true`
2. 在备忘录/Chrome 中按 `⌘⇧V`：面板弹出 → 立即开始识别 → 说话 → 再按 `⌘⇧V` 停止 → 文字插入光标
3. 在 iTerm2 中按 `⌘⇧V`：面板弹出 → 观察是否立即识别（可能需多试几次）
4. 确认听写结束后 Dock 图标消失
5. 用 `⌘↩` 手动粘贴、`Esc` 取消
