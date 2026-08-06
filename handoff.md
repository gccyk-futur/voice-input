# VoiceKit Handoff — 2026-08-06

> 给稍后要自己 debug 的我/你。这份文档只记录：今天为什么改、改了什么、哪些已验证、
> 哪些**没完成**以及最可能的根因与线索。原先 13 个本地提交已压缩为一个基线提交；
> 本轮修复已并入同一提交。

---

## 1. 原始任务（触发点）

新 Mac mini（macOS 26.5.1）**没有默认麦克风**，按快捷键启动听写 → `VoiceKit` 直接
SIGABRT 闪退。

- 崩溃点：`LegacyDictationEngine.start` 的 `inputNode.installTap` 抛 **NSException**
  （无输入设备时 `outputFormat(forBus:0)` 的 sampleRate=0），而 Swift `do/catch` 接不住
  ObjC 异常 → `abort()`。
- 早期崩溃日志：`AVAudioEngineImpl::InstallTapOnNode` + `objc_exception_throw`。

## 2. 已验证的修复（保留）

| 修复 | 验证状态 |
|---|---|
| **无麦不再闪退**：`NSExceptionCatcher`（ObjC @try/@catch 桥接）+ `AudioCapture` 默认输入/硬件 input-output format 预检 + `ASRError.noInputDevice` + NSAlert | ✅ 你测过：弹窗、不崩、Esc 可关；本轮补充了云端 task 前预检 |
| **剪贴板还原**：eager data 快照 + `countAfterWrite` 写在写入之后 | ✅ 你测过：`已恢复 ok=true` |
| **AppKit 回调崩溃**（togglePopover / applicationShouldHandleReopen，swiftlang#89197 的 @MainActor @objc 隔离 thunk bug）→ nonisolated 入口；窗口 delegate 同样用 nonisolated shim | ✅ Debug/Release 两个渠道编译通过；运行时仍需目标机手测 |
| **阿里云连接状态机**：真实握手状态、重连、start 超时；`run-task` 与 `task-finished` 串行化，`task-failed` 后废弃连接；finish 前关闭新音频发送并排空已登记发送；旧 WebSocket 回调按连接代次丢弃 | ✅ 生命周期/事件/启动代次/音频排空/连接代次测试通过；目标机需快速 F2 手测 |
| **Swift 6 音频闭包**：`LegacyDictationEngine` 入队前快照 recognition request，避免并发闭包重复捕获可变 `self` | ✅ Debug/两个 Release 条件编译通过且不再产生该 warning |
| 日志写入 `~/Library/Logs/VoiceKit/voicekit.log` + 主线程看门狗(2s) | 诊断用 |

## 3. ⚠️ 未完成 / 已知问题（重点看这里）

### 3.1 自动写回回归与目标焦点（本轮已恢复已验证基线，待目标机手测）

- **本机日志证据**：`postToPid ... sent=true` 只代表事件成功创建/投递，不能证明目标文本框
  已插入；AX 菜单 action 的 success 也同样不是目标文本变化的证明。此前日志出现这两类
  “成功”但用户输入框为空，和当前症状一致。
- **本机当前 App Store 日志位置**：沙盒版不是写在普通的
  `~/Library/Logs/VoiceKit/voicekit.log`，而是
  `~/Library/Containers/me.ckai.VoiceMate/Data/Library/Logs/VoiceKit/voicekit.log`。
  当前 v6 日志已确认目标为 ChatGPT PID 42768，事件确实发出，但没有插入确认。
- **当前实现**：官网版先尝试 AX value 直插；只有读取并验证目标值确实变化才算成功，否则
  回退剪贴板 + `postToPid`。App Store 版直接走同一条剪贴板 + `postToPid` 自动写回路径。
- **本轮恢复的基线**：`CGEventSource(stateID: .combinedSessionState)`，只向目标 pid 投递
  带 `.maskCommand` 的 V down/up；不再合成 Command down/up，也不再使用未验证落地结果的
  AX 菜单快捷路径。此序列来自旧版 macOS 14+ 渠道包，且在这次改动前实际可用；纯事件计划有
  XCTest 覆盖。
- **v7 修复**：关闭 `.nonactivatingPanel` 后，按 Apple 当前推荐的 cooperative activation
  先 `NSApp.yieldActivation(to:)`，再请求目标 `activate()`，并把粘贴放到下一次主循环；
  `activate()` 返回值只记录“请求被允许”，不再当成焦点或插入成功。自动尝试后剪贴板统一保留
  8 秒，避免自动失败后用户按 `⌘V` 时文字已经被 1 秒计时器恢复。
- **v7 实测结论**：当前 v7 日志显示 `target active=true`、`postToPid sent=true`，但 ChatGPT
  仍未写入；这说明目标焦点和事件构造都不是充分条件，必须检查 Core Graphics 的 PostEvent
  TCC 权限。
- **当前 v8 修复**：接入 Apple 当前 SDK 的 `CGPreflightPostEventAccess()` /
  `CGRequestPostEventAccess()`。该权限独立于官网版 AX Accessibility 权限；未授权时不再发送
  伪成功的 `⌘V`，只保留剪贴板并提示用户授权键盘事件。设置页新增“自动写回”权限卡片；官网版
  的 AX 直插成功路径不额外请求 PostEvent 权限。权限页首次请求被拒绝后会显示“打开系统设置”。
- **当前 v10 修复**：自动写回事件已获授权且成功派发时，不再弹出误导性的“请按 ⌘V”提示；
  同时修正 `LegacyDictationEngine.stop()` 的最终回调竞态，避免识别完成后无谓等待 1.5 秒兜底。
- **已移除**：AX 菜单 Paste 探测/匹配代码。它只能证明 `AXUIElementPerformAction` 被调用，
  无法证明文本已写入，反而会截断可靠的 CGEvent fallback。
- AX 直插现在不再用角色白名单，也不把 `kAXSelectedTextAttribute` 当作写入入口：先读取
  `kAXValueAttribute` 与 `kAXSelectedTextRangeAttribute`，按选区计算完整新值，再确认
  `kAXValueAttribute` 可写并写回；写入值验证成功后，选区恢复仅作 best-effort。写入值未
  验证成功时仍回退剪贴板+⌘V。

### 3.2 快速连续按 F2 会规律性报"阿里 ASR 连接失败"（已改，未完成目标机手测）

- 症状：连续呼出/结束几次后，阿里云引擎报连接失败。可能和 3.1 的输入卡顿窗口叠加
  （主线程/输入被短暂阻塞时，快速 toggle 让 Ali 异步状态机吃到并发 start/stop）。
- 根因已从本地日志确认：前一个 `finish-task` 尚未收到 `task-finished`，新的 `run-task`
  已经发出，服务端返回 `InvalidParameter - run-task received while another task is active`。
  现在引擎生命周期和 coordinator 都会阻止重入；服务端 `task-failed` 会使连接失效并重连。
  WebSocket 替换时会生成新的连接代次，旧连接迟到的 `didOpen`、`didClose`、接收循环不会
  再污染当前连接；重连延时结束时若已有新连接，也不会无条件再开一条连接。
  另外，取消发生在 `resolveASR`/`engine.start` 尚未返回时，旧异步结果也会被启动代次丢弃，
  stop/cancel 会等待 pending start 完成后再调用 `engine.stop()`；finish-task 发送前会原子关闭音频发送入口，
  再等待已经交给 URLSession 的帧发送回调结束，避免最后一帧与 finish-task 乱序。
- 如果 `task-failed` 恰好发生在 stop/cancel 收尾期间，错误现在交给收尾任务统一消费，
  不会与“空结果”或提前 reset 竞态，用户能看到真实的中断原因。
- 第二次 F2 如果发生在 `resolveASR` 尚未完成时，现在会取消待解析流程并复位，不会把 coordinator
  留在 `.recording`，也不会让迟到的引擎启动成幽灵会话。

### 3.3 粘贴是否真正落地无法检测（假阳性）

- `postToPid` 返回 true 只代表事件创建，不代表目标 app 真的粘上了。现状是无辅助功能时
  已做诚实降级（只复制 + 提示），但"⌘V 已投递但目标没粘"仍是假阳性。
- 社区无完美解；可做的改进是"投递后短延时校验目标 app 焦点是否收到文字"，成本高，先不做。

### 3.4 可疑点（如果遇到莫名卡顿，优先查）

- `AccessibilityPasteService.isTrusted` 现在只使用 Apple Accessibility API 的
  `AXIsProcessTrusted()`；不再用事件 tap 能力推断 AX 权限。AX 直插按
  `kAXValueAttribute`/`kAXSelectedTextRangeAttribute` 读取和写入，失败仍回退剪贴板路径。

### 3.5 本轮 Mac mini 实测后的修复

- **耳机重新连接后的 `Failed to create tap due to format mismatch`**：日志已确认失败发生在
  `AudioCapture` 的 `inputNode.installTap`，而不是阿里云 WebSocket。根据 Apple 的
  `AVAudioNode.installTap` 语义，tap 的 `format` 改为 `nil`，让输入节点使用当前路由的
  原生输出格式，再转换到 ASR 的目标格式；新增 `AudioTapFormatPolicyTests` 防止回退到固定硬件格式。
- **App Store 版回写策略**：恢复此前 macOS 14+ 渠道包使用的 `PasteService.postToPid` 自动写回路径；App Store 版也会先尝试自动写回，AX 直写仍仅用于官网版。当前不能从 `postToPid` 返回值判断目标控件是否真正插入，因此自动失败时依赖 8 秒剪贴板窗口手动 `⌘V`。
- **App Store 版配置隔离**：官网版与 App Store 版分别读两个 Application Support 位置。App Store 设置→语音识别新增“导入官网版 config.json”，通过用户选择的 `NSOpenPanel` 和只读 user-selected entitlement 迁移配置，不绕过沙盒静默读取用户目录。
- **状态栏历史空隙**：连接指示点移到引擎 Picker 同一行，去掉填充用 `Spacer`，并让 popover 使用内容的自然高度；引擎切换不再改变面板高度。
- 本轮新增策略断言，移除未验证的 AX 菜单路径后合计 **19 个 XCTest**；官网版 Release 与 App Store Release 条件分支均已用新包重新归档验证。仍需 Mac mini 上实测耳机拔插、两渠道自动写回，以及失败时的手动 ⌘V 流程。

## 4. 涉及文件与线索

| 文件 | 关注点 |
|---|---|
| `Sources/VoiceKit/Paste/PasteService.swift` | **3.1 主战场**：`simulateCmdVviaPostToPid`、剪贴板 save/restore |
| `Sources/VoiceKit/Paste/AccessibilityPasteService.swift` | `isTrusted` 能力探测（3.4）、AX value/selection 插入 |
| `Sources/VoiceKit/Paste/TextInsertionPlan.swift` | AX value 插入的选区替换与光标位置计算 |
| `Sources/VoiceKit/Coordinator/AppCoordinator.swift` | `confirmPaste`、启动代次、pending start teardown、`onFailure` 接线 |
| `Sources/VoiceKit/App/AppDelegate.swift` | nonisolated 入口、主线程看门狗(2s) |
| `Sources/VoiceKit/Support/` | `NSExceptionCatcher`、`Log.swift` |
| `Sources/VoiceKit/ASR/AudioCapture.swift` | 设备预检、tap 桥接、路由变化 |
| `Sources/VoiceKit/ASR/AudioTapFormatPolicy.swift` | tap 使用当前输入节点原生格式的策略 |
| `Sources/VoiceKit/Config/ConfigImportPolicy.swift` | App Store 配置迁移路径与文件选择校验 |
| `Sources/VoiceKit/Paste/PasteDeliveryPolicy.swift` | 官网版自动插入 / App Store 剪贴板降级策略 |
| `Sources/VoiceKit/Coordinator/RecordingFlowGate.swift` | 取消后的异步启动代次保护 |
| `Sources/VoiceKit/ASR/AlibabaASREngine.swift` | 连接状态机、音频发送排空（3.2） |
| `Sources/VoiceKit/ASR/AudioSendDrain.swift` | 每个 task 独立的发送登记/关闭/排空协议 |
| `Sources/VoiceKit/ASR/ConnectionEpoch.swift` | WebSocket 替换时识别并丢弃旧连接回调 |

## 5. Git 历史说明

- 原 13 个本地提交已压缩为一个 `fix: harden macOS audio, ASR, paste, and AppKit edge cases` 提交，
  基于远程 `origin/main`；恢复标签为 `backup/pre-squash-20260806`。
- 本轮修复包含 lifecycle XCTest、CmdV 事件计划 XCTest、RecordingFlowGate XCTest、音频发送排空 XCTest、ConnectionEpoch XCTest、AX value 插入计划 XCTest，以及音频 tap / App Store 粘贴 / 配置迁移 / PostEvent 权限策略测试；官网版与 App Store 版 Release 条件编译均已验证，共 19 个测试；
- 当前提交已分别用 Developer ID Application 和 Apple Distribution archive（当前产物为
  `/private/tmp/voicekit-current-direct-v10.xcarchive` 与 `/private/tmp/voicekit-current-appstore-v10.xcarchive`）；
  两个 `.app` 的签名身份、Team ID、时间戳和 entitlements 均已读回，并在可访问发布证书的环境中通过
  `codesign --verify --deep --strict`。官网包为无沙盒 entitlements，App Store 包为沙盒 entitlements；
  仍未执行公证、上传或覆盖正在运行的旧包。
- 未推送远程。

## 6. 给 debug 者的快速起点

1. 在目标 Mac mini 的签名官网版上验证：单次粘贴、连续三次粘贴、粘贴后 Shift-Return、
   粘贴后立即 F2；记录文本是否落地以及 Command/Shift 是否残留。
2. 连续快速 F2：确认日志中每个被接受的 start 都有对应 `task-finished`，不再出现
   `run-task received while another task is active`。
3. 无麦克风：确认在发送 `run-task` 前直接报无输入设备且不崩溃。
4. 看门狗已降为 2s，主线程若再卡会有 `[Watchdog] 主线程超过 2 秒未响应` 日志可定位。
