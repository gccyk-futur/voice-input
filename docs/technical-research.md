# VoiceKit 技术选型与调研

> 本文档基于两份 PRD（已归档至 `docs/archive/`）整理，为目标 macOS 26 原生 App 的技术决策与可行性调研。
> 调研时间：2026-07-06。环境基线见下文。

---

## 1. 环境基线（实测）

| 项目 | 实测值 | 对方案的影响 |
|------|--------|--------------|
| 操作系统 | macOS 26.4.1 (Tahoe) | 可直接使用 `SpeechAnalyzer`（macOS 26+ 新 API），无需降级兼容旧 API |
| Swift | 6.3.1（swiftlang-6.3.1） | 可用 Swift 6 严格并发（Strict Concurrency），Actor / async-await 全量可用 |
| Xcode | `/Applications/Xcode.app`，`xcodebuild` 可用 | 可编译、签名、打包 `.app` |
| xcodegen | `/usr/local/bin/xcodegen` 可用 | **关键**：用 `project.yml` 文本化生成 `.xcodeproj`，避免手写 pbxproj，工程完全可版本化、可复现 |
| 架构 | 当前为 x86_64 工具链（`Target: x86_64-apple-macosx26.0`），但 Xcode 可编译 `arm64` / `x86_64` / `universal` | 打包时建议 `ARCHS = arm64 x86_64`（Universal）以覆盖 Apple Silicon + Intel |

**结论**：开发环境完备，Xcode 工程可通过 `xcodegen` + `xcodebuild` 全链路构建，无需手动维护工程文件。

---

## 2. ASR（语音转文字）引擎

### 2.1 系统听写（默认，P0）—— 采用 `SpeechAnalyzer`

- **API**：`Speech` 框架新增的 `SpeechAnalyzer` + `SpeechTranscriber`（WWDC25 Session 277《Bring advanced speech-to-text capabilities to your app》）。
- **能力**：端侧实时转写、流式返回 `SpeechTranscriber.Segment`、自动标点、说话人无关的连续识别，性能与准确率优于旧 `SFSpeechRecognizer` 的音频识别模式。
- **用法要点**（实现时以编译为准）：
  - `let transcriber = SpeechTranscriber(configuration: .init(locale: .current, ...))`
  - `let analyzer = SpeechAnalyzer(transcriber: transcriber)`
  - 通过 `AVAudioEngine` 输入节点 `installTap`，将 `AVAudioPCMBuffer` 喂给 `analyzer` 的输入（`analyzer.prepareToAnalyze()` 得到 `AnalyzerInput`，或 `analyzer.feed(buffer)`）。
  - 结果通过 `for try await segment in analyzer.transcripts`（或 `analyzer.transcription`）异步消费。
  - 需在 `Info.plist` 配置 `NSSpeechRecognitionUsageDescription` 与麦克风权限 `NSMicrophoneUsageDescription`。
- **降级兼容（macOS 12–25）**：旧系统无 `SpeechAnalyzer`，回退到 `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest`（流式 `partialResults`）。PRD 要求“自适应”，因此实现一层 `SystemDictationEngine`，内部按 `ProcessInfo.processInfo.operatingSystemVersion` 选择 API。
- **语言包缺失**：系统听写语言包未下载时，`SpeechTranscriber` 初始化会失败/无结果，需捕获并提示用户去「系统设置 > 键盘 > 听写」下载（见 PRD 异常处理）。

### 2.2 Whisper 本地（P1）—— `ggerganov/whisper.spm`

- **方案**：官方 Swift Package 封装 `whisper.cpp`，作为 SPM 依赖引入；Apple Silicon 自动启用 Metal（GGML `GGML_USE_METAL`）。
- **模型文件**：由用户自行下载 `ggml-*.bin` 并通过路径配置（PRD 明确不捆绑，保持 App < 10MB）。
- **集成点**：抽象为 `WhisperEngine`，读取音频 buffer → 调用 whisper 推理 → 返回文本。与系统听写实现同一 `ASREngine` 协议，运行时切换。
- **风险**：首次编译 whisper.cpp 较慢（C++/Metal），CI 或本地需缓存；模型推理在主线程外执行（Actor / DispatchQueue）。

### 2.3 云端 ASR（P1/P2）—— 讯飞 / 阿里云 / OpenAI Whisper API

- 均为“录音 → 上传音频 → 取回文本”的离线批处理模式（非流式实时），与系统听写体验不同。
- 通过标准 `URLSession` 上传音频文件/字节流，按各厂商鉴权（讯飞 WebSocket 签名、阿里云 RPC、OpenAI 文件接口）。
- 抽象为 `CloudASREngine`，同样遵循 `ASREngine` 协议；优先级低于本地引擎，放 v1.2 实现。

**选型结论**：v1.0 MVP 仅实现 `SystemDictationEngine`（自适应 `SpeechAnalyzer` / 降级 `SFSpeechRecognizer`），其余引擎按协议在后续版本插入，不阻塞 MVP。

---

## 3. 全局热键

- **选型**：Carbon `HIToolbox` 的 `RegisterEventHotKey`（`import Carbon.HIToolbox`）。
- **依据（已联网核实，2026 资料一致）**：`RegisterEventHotKey` 是 macOS 上**唯一公开、且不需要辅助功能（Accessibility）权限**的全局热键 API。其它方案（`NSEvent.addGlobalMonitorForEvents`、`CGEvent` 监听）要么只能在前台、要么需要辅助功能权限。
- **自定义快捷键**：解析 `Cmd+Shift+V` 组合为 `(modifiers, keyCode)`，调用 `RegisterEventHotKey` / `UnregisterEventHotKey` 动态注册；切换立即生效，无需重启。
- **冲突检测（P2）**：`RegisterEventHotKey` 返回 `paramErr`/特定错误码表示被系统占用；捕获后提示用户修改。
- **注意**：Carbon 虽被标记 deprecated，但在 macOS 26 仍完全可用，且无替代公开 API，社区（Rust `carbonhotkey` 等）持续维护印证其稳定性。

---

## 4. 模拟粘贴（填入光标位置）

- **选型**：`CoreGraphics` 的 `CGEvent`（构造 `kVK_ANSI_V` 的 keyDown/keyUp + 修饰符 `cmd`，或发送 `CGEvent(keyboardEvent:...)`）。
- **权限**：**必须**辅助功能权限（「系统设置 > 隐私与安全性 > 辅助功能」添加 App）。PRD 异常处理已覆盖。
- **替代**：也可通过 `NSPasteboard` 写入剪贴板后派发 `Cmd+V`；但苹果推荐直接用 `CGEvent` 模拟，体验更连贯。实现时优先 `CGEvent`，失败回退「复制剪贴板 + 提示手动粘贴」。
- **设计**：粘贴动作放在悬浮窗 `Cmd+Enter` 确认后执行；`CGEvent.post(tap: .cghidEventTap, location: .tail)`。

---

## 5. 悬浮窗（Floating Panel）

- **选型**：`NSPanel`（`.nonactivatingPanel` 样式，避免抢焦点）+ `NSHostingView` 承载 SwiftUI `View`，内部用 `NSVisualEffectView`（`.hudWindow` / `.popover` 材质）实现毛玻璃。
- **关键属性**：
  - `styleMask = [.nonactivatingPanel, .titled, .closable, .resizable]`（酌情）
  - `level = .floating`（或 `.modalPanel`）置顶
  - `isFloatingPanel = true`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
  - 背景模糊 + 半透明，支持深色/浅色（`NSAppearance` 跟随系统）
- **实时双区**：上半区 ASR 原始（灰色，实时刷新），下半区润色结果（黑色，逐字追加）。用 SwiftUI `@State`/`@Observable` 驱动。
- **拖拽移动（P1）**：在标题栏/背景添加 `NSDragging` 或 SwiftUI `dragGesture` + 调整 `panel.frameOrigin`。
- **状态/音量（P0/P2）**：状态文本；音量波形用 `AVAudioEngine` 的 `installTap` 取 RMS 绘制小波形。

---

## 6. LLM 润色引擎（流式）

- **协议**：`LLMEngine` 暴露 `func polish(_ text: String) -> AsyncThrowingStream<String, Error>`（逐字/逐 token 流式）。
- **实现方式**：`URLSession` + 流式响应。
  - OpenAI / DeepSeek / 自定义（兼容 `/v1/chat/completions`，`stream: true`）：解析 SSE（`data: {...}\n\n`），累加 `choices[0].delta.content`。
  - Ollama（本地 `http://localhost:11434/api/chat`，`stream: true`）：同样 SSE/JSON 流。
  - Anthropic Claude：使用其 `/v1/messages` 流式（SSE `content_block_delta`）。
- **并发**：Swift 6 严格并发下，网络与解析放在非隔离上下文（`NonSendable` 数据用 `Actor` 隔离或 `@unchecked` 谨慎处理），UI 更新回到主线程。
- **Prompt 变量**：`{{input}}`、`{{language}}`、`{{engine}}`、`{{timestamp}}`、`{{custom.xxx}}`，在发送前做字符串替换（见 PRD-2）。
- **默认关闭**：PRD 默认 `enabled = false`，仅当用户开启且配置引擎后才调用。

---

## 7. 配置与存储

| 数据 | 存储 | 说明 |
|------|------|------|
| 全量配置 `config.json` | `~/Library/Application Support/VoiceMate/config.json` | `JSONEncoder/Decoder`；UI 与文件双优先，文件变更用 `DispatchSource.FileSystemEvent` 热重载 |
| 敏感字段（API Key） | **Keychain**（Security 框架） | 配置文件中仅存占位符/`****`，绝不明文落盘 |
| 运行期偏好（如窗口位置） | `UserDefaults` | 轻量 |
| 历史记录 `history.json` | `~/Library/Application Support/VoiceMate/history.json` | 20 条 JSON（PRD 建议数据量小用 JSON 即可，无需 SQLite） |
| 导入/导出 | 文件读写 + Keychain 写入 | 导出时 API Key 脱敏为 `****` |

- **Keychain 封装**：PRD 强调“零外部依赖”，优先用 `Security/SecItem*` 直接封装一个小 `KeychainStore`（约 60 行），不引入第三方库；若后续繁琐再考虑 `KeychainAccess` SPM。
- **配置文件监控**：`DispatchSourceFileSystemEvent` 监听 write/delete/rename，解析成功则热重载并通知引擎；解析失败回退上次有效配置并提示。

---

## 8. 构建与工程化

- **工程生成**：`xcodegen` 读取 `project.yml` 生成 `VoiceMate.xcodeproj`（文本可版本化，避免手工维护 pbxproj）。
- **构建验证**：`xcodebuild -project VoiceMate.xcodeproj -scheme VoiceMate -configuration Release build`（或 `archive`）。
- **打包**：`xcodebuild -archivePath` + `ExportOptions.plist` 导出 `.app`；菜单栏 Agent 用 `LSUIElement = true`（不出现在 Dock）。
- **依赖管理**：MVP 阶段仅用 Apple 框架（零 SPM 依赖）；whisper.cpp 与可选库通过 SPM 在 v1.2 引入。
- **权限声明**：`Info.plist` 需 `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`；辅助功能权限运行时引导。
- **体积**：不含模型 < 10MB，纯 Swift + AppKit/SwiftUI 完全可达。

---

## 9. 风险与决策清单

| 风险点 | 影响 | 决策 |
|--------|------|------|
| `SpeechAnalyzer` API 细节以编译为准 | 实现时需验证符号 | MVP 先用已知用法写，编译校验修正 |
| `RegisterEventHotKey` 被标记 deprecated | 未来可能移除 | 当前唯一免辅助功能方案，先用；关注 Sequoia/Tahoe 后是否有新 API |
| 辅助功能权限被拒导致无法粘贴 | 核心流程阻断 | 降级：写剪贴板 + 提示用户手动 `Cmd+V` |
| 系统听写语言包未下载 | 转写失败 | 捕获错误 → 引导下载 |
| 严格并发（Swift 6）红线 | 编译报错 | 统一用 Actor 隔离引擎状态，UI 走 `@MainActor` |
| App 体积 / 签名 | 分发 | Universal 架构 + Developer ID 签名（发布阶段） |

---

## 10. 技术选型总表（结论）

| 层级 | 选型 | 备注 |
|------|------|------|
| 语言 | Swift 6.3（严格并发） |  |
| UI | SwiftUI + AppKit（NSPanel 承载） | 毛玻璃用 NSVisualEffectView |
| 录音 | AVFoundation (`AVAudioEngine`) | 供 SpeechAnalyzer / whisper 使用 |
| ASR（默认） | SpeechAnalyzer（macOS 26）/ SFSpeechRecognizer（降级） | 自适应 |
| ASR（可选） | whisper.spm（whisper.cpp） | v1.2 |
| 热键 | Carbon `RegisterEventHotKey` | 免辅助功能 |
| 粘贴 | CoreGraphics `CGEvent` | 需辅助功能 |
| LLM | URLSession 流式 SSE（OpenAI/Ollama/DeepSeek/Claude 兼容） | 协议可插拔 |
| 存储 | JSON 文件 + UserDefaults + Keychain | 敏感字段入 Keychain |
| 构建 | xcodegen + xcodebuild | 文本化工程 |
| 工程形态 | 菜单栏 Agent（`LSUIElement`） | 不占 Dock |

下一步：基于以上选型，进入 `docs/architecture.md` 的技术架构设计。
