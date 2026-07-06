# VoiceMate 调试交接备忘录（handoff）

> 生成时间：2026-07-07 00:19
> 目标：把今天（2026-07-06 晚）调试 VoiceMate 的完整上下文固化下来，明天接着干。

---

## 1. 项目概述

- **VoiceMate**：macOS 语音输入 app。全局热键 `⌘⇧V` 唤起 → 说话 →（可选 LLM 润色）→ 自动把文字插入当前光标位置。
- 技术栈：Swift 6、SwiftUI、xcodegen（`project.yml`）、部署目标 macOS 26.0、架构 `arm64 x86_64`。
- 入口/中枢：`Sources/VoiceMate/Coordinator/AppCoordinator.swift`（`@MainActor @Observable`，状态机）。
- 构建：`xcodebuild -scheme VoiceMate -configuration Debug build`。我本地验证用 ad-hoc 签名 `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`（**注意见第 6 节签名陷阱**）。

---

## 2. 架构与文件职责

| 文件 | 职责 |
|---|---|
| `Coordinator/AppCoordinator.swift` | 状态机 `idle→recording→transcribing→polishing→ready`；驱动各服务；`enterForeground/exitForeground`（agent↔前台切换）；`confirmPaste`（收尾粘贴）；`reset`。 |
| `ASR/SystemDictationEngine.swift` | **主力引擎**：`SpeechAnalyzer` + `DictationTranscriber`（系统连续听写的本地模型，与系统"听写"同源）。负责音频采集、转写、分句累计。 |
| `ASR/LegacyDictationEngine.swift` | 服务器回退引擎：`SFSpeechRecognizer`。已修复 16kHz 转换（`Code=203 Corrupt`）。 |
| `ASR/ASREngine.swift` / `ASRError.swift` | 协议与错误。 |
| `Paste/PasteService.swift` | 粘贴：优先辅助功能 `kAXSelectedTextAttribute` 光标插入；回退写剪贴板 + 模拟 `⌘V`。 |
| `Panel/FloatingPanelController.swift` | `NSPanel`（`.floating` 级别、`canJoinAllSpaces`+`fullScreenAuxiliary`），`makeKey()`、`installKeyMonitor`（⌘↩ 粘贴 / Esc 取消）。 |
| `Hotkey/HotkeyManager.swift` | Carbon `RegisterEventHotKey` 全局热键；C 回调里现在做"趁用户事件上下文激活 app"。 |
| `LLM/*` | Ollama / OpenAI / DeepSeek / custom 润色（与当前 bug 无关）。 |

---

## 3. 状态机

```
idle --(⌘⇧V)--> recording --(⌘⇧V)--> transcribing --(结束)--> [polishing]? --> ready --(自动)--> confirmPaste --> reset --> idle
```
- `toggleRecording`：`idle→startRecording`，`recording→stopAndProcess`，其余状态 `break`（避免重复粘贴）。
- `confirmPaste` 必须**无论成败都 `reset()`**（否则状态卡 `.ready`、热键被忽略、无法再次呼出——这是之前"无法再次呼出"的根因，已修）。
- `finalizing` 标志：自动粘贴收尾期间，屏蔽面板关闭触发的 `cancel`，避免双重复位。

---

## 4. 五个核心问题及当前状态（截至今晚）

| # | 现象 | 状态 | 已做的根因/修复 |
|---|---|---|---|
| 1 | 呼出后**必须点一下面板**才开始识别 | ❌ 仍未解决 | 见第 5 节"激活"主线 |
| 2 | 文本**停顿后清空**、重新识别 | ⚠️ 疑似复发 | 见第 5 节"累计"主线 |
| 3 | 文本**整句重复追加**（"X？X？"） | ⚠️ 疑似复发 | 见第 5 节"累计"主线 |
| 4 | 停止后**文字不进光标** | ❌ 仍未解决 | 见第 5 节"粘贴"主线 + 签名陷阱 |
| 5 | 可重复呼出 | ✅ 已解决 | `confirmPaste` 必 `reset()` |

> 用户最新反馈（00:19）："这些问题都还存在，而且语音识别的复写问题又回退了。" 即 #1/#3/#4 仍在，#2/#3 的累计修复疑似没生效或回归。

---

## 5. 三条主线（重要，按此继续）

### 5.1 主线 A：识别必须点击面板（#1）
**根因假设**：系统听写 daemon（`DictationTranscriber` 背后）**只在 app 处于激活(active)态时才回传结果**。app 不激活 → 识别沉默 → 点面板（真实用户事件）后才激活。

**已确认事实**：
- `project.yml` 里 `LSUIElement: true` → 本 app 是 **agent（后台）应用**。agent 应用调用 `NSApp.activate(ignoringOtherApps:)` 会被系统忽略（除非在用户事件上下文）。
- 必须先把进程从 UIElement 变 Foreground（`TransformProcessType`），agent 才能被激活。
- **关键陷阱**：原热键回调用 `DispatchQueue.main.async` 延后执行 `NSApp.activate`，脱离了"热键用户事件"上下文 → 激活被忽略 → 面板不在最上层、识别不开始。

**已尝试的修复（今晚）**：
- `AppCoordinator.enterForeground()` 用 `TransformProcessType(&psn, kProcessTransformToForegroundApplication)`（替换了无效的 `NSApp.setActivationPolicy(.regular)`，后者对运行中 agent 不生效）。`exitForeground()` 还原为 `kProcessTransformToUIElementApplication`。
- `HotkeyManager` 的 C 回调里，趁热键事件刚送达、仍在用户事件上下文，**同步**做：① `TransformProcessType` 变前台；② `MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }`；③ 之后才 `async` 跑 `onActivate`。
- `FloatingPanelController.show()` 里 `panel?.orderFrontRegardless(); panel?.makeKey()`（让面板成为 key window）。

**⚠️ 但用户实测 #1 仍在** → 说明上面的激活仍未真正生效。明天优先验证"激活到底有没有发生"。
**明天验证手段（强烈建议先加日志）**：
- 在 `SystemDictationEngine.start()` 真正 `audioEngine.start()` 之前/之后打印：
  - `NSApp.isActive`、`NSRunningApplication.current.isActive`、`panel?.isKeyWindow`
  - 是否收到 `transcriber.results` 第一个元素、以及首元素到达的耗时。
- 若 `results` 迟迟不来 → 激活确实没生效；若来了但 UI 没更新 → 别的问题。

**明天备选方案（若激活仍失败）**：
- 直接把 app 改成**普通前台应用**（临时移除 `LSUIElement`）做对照实验，验证热键能否激活。
- 或在热键上下文里同时 `NSApp.setActivationPolicy(.regular)`。
- **架构级备选**：`DictationTranscriber` 的"仅激活 app 才转写"是硬约束。若始终搞不定，考虑换用**不要求 app 激活**的本地引擎（如本地 Whisper，audio buffer 进程内推理，无 daemon 门禁）——但这是大改，且用户偏好"系统同源本地听写"，需先与用户确认。

### 5.2 主线 B：分句累计 / 重复 / 清空（#2 #3）
**SDK 事实**（`Speech.framework` 的 `DictationTranscriber.Result` swiftinterface 确认）：
- 属性只有 `range: CMTimeRange`、`resultsFinalizationTime: CMTime`、`text: AttributedString`、`alternatives`。**没有 `isFinal`**。
- `text` 是**当前这一句(phrase)** 的文本，**不是累计全文**。
- 定稿判定：`result.resultsFinalizationTime.isValid`（定稿前为 invalid）。
- 同一句会被反复修订（流式→定稿，定稿后还可能迟到重发一次）。

**演进**：
1. 初版 `finalText = text`（整句覆盖）→ 停顿清空（#2 的根因）。
2. 改 `committed/current` 追加 → 整句重复（#3 根因：定稿后迟到重发被当新内容追加）。
3. 改 `range.start` 匹配原地替换 → 仍重复（start 时间不完全一致）。
4. **当前版本（今晚）**：`transcript`（已定稿）+ `current`（当前句最新文本）+ `lastCommitted`（上一句定稿，用于忽略迟到重发）+ `appendCommitted`（修正版去尾追加）。判定逻辑：
   - `finalized`（resultsFinalizationTime.isValid）→ 提交 `current`/该句，清 `current`。
   - 流式且 `current` 非空且与新文本**非精炼关系**（`!isRefinement`）→ 先提交上一句，开始新句。
   - `isRefinement(prev,next)` = `next==prev || next.hasPrefix(prev) || prev.hasPrefix(next)`。
   - 迟到重发忽略：当 `current` 为空且新文本与 `lastCommitted` 是前缀包含关系时 `continue`。

**⚠️ 用户实测 #2/#3 仍/复发** → 当前模型仍有漏洞。已知边缘缺陷：
- 迟到重发的忽略仅在 `current.isEmpty` 时生效；若迟到重发在**新句已开始**（`current` 非空）时到达，会被误判为新句 → 乱序/重复。
- 若 `resultsFinalizationTime.isValid` 实际**永远为 false**（框架不发定稿信号），则完全依赖 `isRefinement` 的新句判定；当两个句子恰好是前缀包含关系时会误判。

**明天方向**：
- 先打印 `result.resultsFinalizationTime.isValid` 的真假分布，确认定稿信号到底来不来。
- 更稳的累计：把"已提交文本"当作整体，新结果到来时判断它是**已提交内容的精炼/延伸还是全新句**，用"与 `transcript` 末尾的包含关系"来去重，比单纯 `current`/`lastCommitted` 更鲁棒。
- 或者退一步：既然 `text` 是 per-phrase，考虑直接**按 `range` 的全局时间轴**维护一个有序分段数组（每段记录 `[CMTimeRange, text]`），每次结果按其 `range` 做"覆盖/插入/扩展"，最终按时间排序拼接——这是最贴合 SDK 语义的做法，推荐作为明天的主攻实现。

### 5.3 主线 C：停止后不进光标（#4）
**逻辑已修**：`PasteService.paste` 现在**无论是否授权辅助功能**都走"写剪贴板 + 模拟 ⌘V"（⌘V 是普通按键，不需授权）。`confirmPaste` 在真正插入前**再次 `target.activate`** 并留 0.3s+0.2s 延时，确保焦点还给目标 app。

**仍未解决** → 焦点没可靠还给备忘录 / 或目标文本域没重新获得光标。
**关键陷阱——签名（必读）**：
- 辅助功能授权**按 app 的代码签名绑定**。本机验证包是 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`），每次构建签名都变 → 你在系统里授予的授权**不匹配** → `AXIsProcessTrusted()` 返回 false，AX 光标插入走不了，只能靠剪贴板+⌘V 兜底。
- **务必用 Xcode `Run` 跑**（Automatic 签名、签名稳定），授权才生效，AX 插入（最稳、不依赖焦点）才能用上。
- 若用户一直在跑 ad-hoc 包测试，#4 必然失败——先确认他用的是 Xcode Run 的包。

**明天方向**：
- 若 Xcode Run 下 AX 仍不进光标：改用"粘贴前用 AX 显式聚焦目标文本框"（`kAXFocusedUIElementAttribute` → `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)`），需要 AX 信任。
- 加日志：`insertViaAccessibility` 返回值、`isTrusted`、`target.activate` 后 `NSWorkspace.shared.frontmostApplication` 是否为目标。

---

## 6. 其他已知事项

- **locale 警告** `cannot use modules with unallocated locales [zh_CN (fixed zh_CN)]`：非致命，听写仍工作。是 `zh_CN` legacy 形式与框架"已分配"形式的提示，官方说"未来版本才报错"。`DictationTranscriber.supportedLocale(equivalentTo:)` 已用于解析本机模型 locale，强行规范化有破坏风险，**暂不动**。
- **`LegacyDictationEngine`**：`Code=203 Corrupt`/`Retry`、`throwing -10877` 已通过"硬件格式→16kHz 单声道 Float32 转换"修复；中文服务器识别可用。目前仅当 `supportedLocale` 解析不到本地模型时回退。
- **`project.yml`**：`OTHER_LDFLAGS: "-framework ApplicationServices"`（框架依赖写法才能链接，`dependencies: framework` 写法失败过）。`ENABLE_HARDENED_RUNTIME: true`、`CODE_SIGN_STYLE: Automatic`。

---

## 7. 明天开局检查清单

1. **先加日志**定位 #1：热键触发→`NSApp.isActive`/`isKeyWindow`/首结果到达耗时。确认激活是否真的发生。
2. 加日志确认 `resultsFinalizationTime.isValid` 分布（决定 #2/#3 的累计策略）。
3. 确认用户测试的是 **Xcode Run 的包**（签名稳定、AX 授权才有效），否则 #4 必然失败、且会误导判断。
4. 按第 5.1/5.2/5.3 的"明天方向"推进，优先攻克 #1（激活），因为它是 #2/#3 部分表现（点面板后正常）的共同前置。
5. 累计推荐使用 **按 `range` 时间轴的有序分段数组** 实现（最贴合 SDK 语义，避免前缀判定的边缘 bug）。

---

## 8. 一句话总结给明天的自己

> 所有症状（须点击才识别、清空、重复、不进光标）很可能**共同根因 = app 没真正激活**（主线 A）。先验证激活、加日志；累计用 range 时间轴分段数组重写；粘贴让用户用 Xcode Run 以让 AX 授权生效。别再用 ad-hoc 包测试下结论。
