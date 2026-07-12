# VoiceKit 技术架构设计

> 承接 `docs/technical-research.md`。本文定义模块边界、可插拔引擎协议、核心数据流与工程目录，作为 `docs/../Sources` 实现的蓝图。
> 范围：先落地 v1.0 MVP（系统听写 + 悬浮窗 + 热键 + 粘贴 + 基础设置 + 历史 + 配置落盘），引擎协议预留 v1.1/v1.2 扩展点。

---

## 1. 分层架构

```
┌───────────────────────────────────────────────────────────┐
│                         UI 层                               │
│  MenuBarExtra（状态栏菜单）  ·  SettingsView（设置）          │
│  PanelView（SwiftUI，悬浮窗双区：ASR灰 / LLM黑）             │
└───────────────┬───────────────────────────┬───────────────┘
                │ 绑定                        │ 命令
                ▼                             ▼
┌──────────────────────────────┐  ┌──────────────────────────────┐
│       AppCoordinator          │  │       Service 层              │
│  ( @Observable 中枢状态机 )    │  │ HotkeyManager / PasteService  │
│  - 会话状态机                  │  │ ConfigStore / HistoryStore    │
│  - 引擎解析与切换              │  │ KeychainStore                 │
│  - 串联 ASR→LLM→粘贴→历史     │  └──────────────────────────────┘
└───────────────┬──────────────┘
                │ 依赖（协议）
        ┌───────┴────────┐
        ▼                ▼
┌──────────────┐  ┌──────────────┐
│  ASREngine   │  │  LLMEngine   │   ← 可插拔协议
│  (协议)       │  │  (协议)       │
├──────────────┤  ├──────────────┤
│ SystemDict.  │  │ OllamaEngine │
│ Whisper*     │  │ OpenAICompat.│
│ CloudASR*    │  │ Claude*      │
└──────────────┘  └──────────────┘
        │                │
        ▼                ▼
   AVFoundation      URLSession(SSE)
   (AVAudioEngine)   流式 HTTP
```

`*` 为后续版本；MVP 仅实现 `SystemDictationEngine` 与 `OllamaEngine`/`OpenAICompatibleEngine`（LLM 默认关闭，但协议与最简实现先就位，便于联调）。

---

## 2. 可插拔引擎协议

### 2.1 ASR 协议

```swift
/// 语音转文字引擎协议：所有 ASR 实现（系统/whisper/云端）遵循。
@MainActor
protocol ASREngine: AnyObject {
    var id: String { get }                       // "system" | "whisper" | ...
    var displayName: String { get }

    /// 开始识别，partials 为实时中间结果流（主线程回调）。
    func start(locale: Locale, onPartial: @escaping (String) -> Void) async throws
    /// 结束识别，返回最终文本。
    func stop() async throws -> String
}
```

- `SystemDictationEngine`：内部按 `ProcessInfo` 系统版本选择 `SpeechAnalyzer`（macOS 26+）或降级 `SFSpeechRecognizer`。
- `WhisperEngine` / `CloudASREngine`：v1.2 实现，遵循同一协议，运行时由 `AppCoordinator.resolveASR()` 切换。

### 2.2 LLM 协议（流式）

```swift
/// 润色引擎协议：返回逐 token 的异步流。
protocol LLMEngine: AnyObject {
    var id: String { get }                       // "ollama" | "openai" | ...
    var displayName: String { get }

    /// 润色 text，逐段返回（token 增量）。
    func polish(_ text: String, system: String, userTemplate: String) -> AsyncThrowingStream<String, Error>
}
```

- 统一用 `StreamingClient`（基于 `URLSession` + `bytes(for:)` 解析 SSE/JSON 流）支撑 Ollama、OpenAI、DeepSeek、Claude、自定义。
- `AppCoordinator` 在 ASR 产出稳定片段或结束时，若 `config.llm.enabled` 为真，则启动 `polish`，把增量 append 到下半区。

---

## 3. 核心数据流（会话状态机）

```
[idle]
  │ 热键 Cmd+Shift+V
  ▼
[recording] ── ASR.onPartial ──▶ PanelView.asrText（灰，实时）
  │ 用户停止（再按热键 / 松开 / 点取消）
  ▼
[transcribing] ── ASR.stop() ──▶ 最终文本 finalText
  │
  ├─ llm.enabled == false ──▶ [ready] finalText 直接待粘贴
  │
  └─ llm.enabled == true  ──▶ [polishing] ── LLM.polish ──▶ PanelView.llmText（黑，逐字）
                                          │
                                          ▼
                                       [ready]
  │ Cmd+Enter
  ▼
PasteService.paste(待粘贴文本) ──▶ HistoryStore.append(asr:finalText, llm:llmText?) ──▶ 关闭面板 ──▶ [idle]
```

- 待粘贴文本 = `llm.enabled ? llmText : finalText`。
- 状态机由 `AppCoordinator.sessionState`（`@Published`/`@Observable`）驱动 PanelView 的「正在录音…/正在润色…/完成」提示。

---

## 4. 关键模块设计

### 4.1 AppCoordinator（`@Observable` 中枢）
- 持有 `ConfigStore`、`HistoryStore`、`HotkeyManager`、`PasteService`、`FloatingPanelController`。
- `sessionState`、`asrText`、`llmText`、`statusText` 供 UI 绑定。
- `toggleRecording()`：idle→recording 开面板起引擎；recording→停止转写进入后续态。
- `confirmPaste()`：`PasteService.paste` + 写历史 + 关面板 + 复位。
- `resolveASR()` / `resolveLLM()`：依据 `AppConfig` 返回对应引擎实例（缓存 + 切换）。

### 4.2 HotkeyManager
- `import Carbon.HIToolbox`，`RegisterEventHotKey` 注册 `Cmd+Shift+V`（可自定义）。
- 回调通过 `DispatchQueue.main.async` 调 `coordinator.toggleRecording()`。
- `register(...) / unregister()` 支持自定义快捷键热切换；冲突返回错误 → 提示。

### 4.3 FloatingPanelController
- 创建 `NSPanel`（`styleMask: [.nonactivatingPanel, .titled]`、`level: .floating`、`collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`）。
- `contentView` = `NSHostingView(rootView: PanelView().environment(coordinator))`。
- 背景 `NSVisualEffectView`（`material: .hudWindow`，`state: .active`）实现毛玻璃；`NSAppearance` 跟随系统深浅色。
- `Cmd+Enter` 在 PanelView 内用 `KeyboardShortcut` 绑定到 `confirmPaste()`；`Esc`/取消按钮关面板。

### 4.4 PasteService
- `CGEvent(keyboardEvent: source: virtualKey: kVK_ANSI_V, keyDown: true)` + 修饰符 `CGEventFlags.maskCommand`，`post(tap: .cghidEventTap, location: .tail)`。
- 辅助功能权限缺失：`AXIsProcessTrustedWithOptions` 检测 → 弹窗引导；失败时回退「写 `NSPasteboard` + 提示手动 `Cmd+V`」。

### 4.5 ConfigStore / KeychainStore
- `AppConfig: Codable`（`general / asr / llm` 三段，字段见 PRD-2 的 config.json）。
- 读写 `~/Library/Application Support/VoiceMate/config.json`；`JSONEncoder/Decoder`。
- `DispatchSource.FileSystemEvent` 监听文件变更 → 解析成功热重载并通知引擎；失败回退上次有效配置并提示。
- `KeychainStore`：`SecItemAdd/Update/Copy/Delete` 封装，存 `apiKey` 等；配置文件内仅 `****`。

### 4.6 HistoryStore
- `HistoryItem: Codable`（`id/timestamp/asrResult/llmResult/engine/llmEngine/favorite`）。
- `history.json`（20 条，超出按 `maxCount` 裁剪，收藏项保底）。
- 方法：`append / remove / clear / toggleFavorite`。

### 4.7 Prompt 变量替换
- `PromptTemplate.render(input:language:engine:timestamp:custom:)` → 替换 `{{input}}` 等占位符，供 LLM 引擎使用（PRD-2 §2.2）。

---

## 5. 工程目录结构

```
VoiceKit/
├── project.yml                 # xcodegen 工程定义
├── ExportOptions.plist         # 打包导出（发布用）
├── Sources/
│   └── VoiceKit/
│       ├── App/
│       │   ├── VoiceMateApp.swift          # @main，MenuBarExtra + NSApplicationDelegateAdaptor
│       │   ├── AppDelegate.swift           # 启动 Coordinator / 权限引导
│       │   └── StatusBarMenu.swift         # 状态栏菜单（设置/历史/退出）
│       ├── Coordinator/
│       │   └── AppCoordinator.swift        # @Observable 中枢 + 状态机
│       ├── Hotkey/
│       │   └── HotkeyManager.swift
│       ├── Panel/
│       │   ├── FloatingPanelController.swift
│       │   └── PanelView.swift
│       ├── ASR/
│       │   ├── ASREngine.swift
│       │   └── SystemDictationEngine.swift
│       ├── LLM/
│       │   ├── LLMEngine.swift
│       │   ├── StreamingClient.swift
│       │   ├── OllamaEngine.swift
│       │   └── OpenAICompatibleEngine.swift
│       ├── Paste/
│       │   └── PasteService.swift
│       ├── Config/
│       │   ├── AppConfig.swift
│       │   ├── ConfigStore.swift
│       │   └── KeychainStore.swift
│       ├── History/
│       │   ├── HistoryStore.swift
│       │   └── HistoryItem.swift
│       ├── Prompt/
│       │   └── PromptTemplate.swift
│       ├── Settings/
│       │   └── SettingsView.swift
│       └── Resources/
│           └── Info.plist                 # 权限描述 + LSUIElement
└── docs/                                # 本文档与调研
```

---

## 6. 权限与 Info.plist 要点

| Key | 用途 |
|-----|------|
| `NSMicrophoneUsageDescription` | AVFoundation 录音 |
| `NSSpeechRecognitionUsageDescription` | 系统听写 |
| `LSUIElement` = `true` | 菜单栏 Agent，不进 Dock |
| `NSAppleEventsUsageDescription` | （可选） |

辅助功能权限（粘贴用）运行时以 `AXIsProcessTrusted` 检测并引导，不在 plist 声明。

---

## 7. 构建与验证

- 生成工程：`xcodegen generate`（依据 `project.yml`）。
- 构建：`xcodebuild -scheme VoiceMate -configuration Debug build`。
- 运行：打开生成的 `VoiceMate.xcodeproj`，Run；菜单栏出现图标 → 按 `Cmd+Shift+V` 测试录音 → `Cmd+Enter` 粘贴。
- MVP 验收：零配置启动、系统听写实时转写、悬浮窗毛玻璃、粘贴入光标、设置可改 ASR 引擎与开启 Ollama 润色、配置与历史落盘。

---

## 8. 版本映射（实现顺序）

| 阶段 | 实现内容 | 协议/扩展点 |
|------|----------|-------------|
| v1.0（本次开发） | 工程骨架 + Coordinator + 热键 + 悬浮窗 + 系统听写 + 粘贴 + 基础设置 + 配置/历史落盘 | ASR/LLM 协议就位 |
| v1.1 | Ollama 润色默认打通 + 自定义快捷键 | LLMEngine 实装 Ollama/OpenAI |
| v1.2 | Whisper 本地 ASR + 讯飞/阿里/OpenAI Whisper ASR | ASREngine 实装 Whisper/Cloud |
| v1.3 | 自定义 Prompt 多模板 + 音量指示 + 快捷键冲突检测 | PromptTemplate 扩展 |

下一步：按 `Sources/` 目录实现 v1.0 MVP。
