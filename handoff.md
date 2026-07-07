# VoiceMate 开发交接备忘录

> 本文件由人工在下班 / 交接时更新；开发过程不在此记录，进展见 git 历史。

## 当前状态（2026-07-07 下班前）

### 本次会话已完成
1. **去掉 Keychain，API Key 明文存 config.json**（`ConfigStore.swift` / `Info.plist`）。原因：之前反复弹 Keychain 密码的根因是 Xcode 没选 Team → 临时签名 → Keychain 按签名绑定每次认成新 app。选 Team 后签名稳定，但明文方案已落地，Keychain 弹窗彻底没了。`KeychainStore.swift` 保留未删。
2. **系统风格组合键录制控件**（`Hotkey/HotkeyRecorder.swift` 新文件，`SettingsView` 接入；保存后即时重新注册热键）。支持点击录制、ESC 取消、忽略单独修饰键。
3. **热键键码表扩展**（`HotkeyManager`）：新增 `F1–F12`、方向键、`Return/Esc/Tab/Delete`。`format()` 反向方法 + `nonisolated` 化。
4. **热键 auto-repeat 冷却 0.4s**（`HotkeyManager`）：按住热键时系统重复 keyDown 会二次触发 `toggleRecording` 把刚启动的听写立刻停掉（面板"闪一下"）。已加冷却过滤。
5. **工程签名固化**（`project.yml`）：`bundleIdPrefix: me.ckai`、`PRODUCT_BUNDLE_IDENTIFIER`/`CFBundleIdentifier: me.ckai.VoiceMate`、`DEVELOPMENT_TEAM: F2J85LVHS4`。以后 `xcodegen generate` 不再清掉手动选的 Team / Bundle ID。
6. **启动失败 UX 稳住**（`AppCoordinator`）：
   - 启动前**预检**麦克风/语音识别授权，`denied` 直接弹错误面板、**不进前台**（无 Dock 闪）；
   - `engine.start` 的 catch 保留面板与前台、显示可读错误、自动打开对应系统设置页；
   - `engine.start` 抛错时打印 `[Coordinator] engine.start failed: <error>` 便于定位；
   - `SystemDictationEngine.start` 抛错时清理 audioEngine/tap，避免下次启动 tap 残留。
7. **`PasteService`** 新增 `openMicrophoneSettings()` / `openSpeechSettings()`。

### ⚠️ 未决问题（下班前未解决）

**症状**：按热键后麦克风授权失败，日志 `[Coordinator] engine.start failed: microphoneNotAuthorized`。

**根因（双重问题）**：
1. TCC 授权按签名身份绑定。Bundle ID / 签名变更后，系统设置里手动勾的授权挂在旧身份上，新实例永远 `.denied`。
2. **代码层面**：`SystemDictationEngine.start()` 在后台 Task 里调用 `AVCaptureDevice.requestAccess`，macOS 上 agent app（LSUIElement）的系统对话框可能**静默不弹出**，`requestAccess` 返回 `false` 且不显示任何 UI。表现为：`tccutil reset` 后状态回到 `.notDetermined`，但按热键仍报 `microphoneNotAuthorized`，系统设置→麦克风里找不到 VoiceMate 条目。

**代码修复（本次会话）**：
- `startRecording()` 新增 `.notDetermined` 的显式处理：在 MainActor 上先进入前台 + 显示面板，再从 MainActor 调用 `requestAccess`，确保系统对话框可靠弹出。
- 新增 `[Coordinator] startRecording: micStatus=... speechStatus=...` 调试日志。

**快速修复步骤（权限卡死后执行）**：
1. **彻底退出所有 VoiceMate 进程**（含菜单栏图标上的残留进程）。
2. 确认终端有全磁盘访问权限（系统设置 → 隐私与安全性 → 全磁盘访问 → 勾上终端），否则 `tccutil reset` 无提示地不生效。
3. 终端执行：
   ```bash
   tccutil reset Microphone
   tccutil reset SpeechRecognition
   ```
   若输出 `Successfully reset ...` 即成功；若无输出，检查第 2 步。
4. **Xcode RUN**（Team 签名，别用 ad-hoc 命令）。
5. 按热键 → 系统弹出授权框 → 点「允许」。

**验证清单**：重新授权后 RUN，按热键（轻点别按住）→ 应稳定显示面板并开始听写；停止后自动粘贴到前台 app 光标处。

### 已知待办（历史遗留）
- OpenAI/DeepSeek 引擎 baseUrl 的 path 被 `/chat/completions` 覆盖丢失 `/v1`（bug 未修，见 commit f0422ae 之外的待办）。
- iTerm2 激活仍可能不稳定（clickToActivate 对抗 reclaim 激活）。
- 听写期间 Dock 图标短暂显示（`TransformProcessType` 副作用，已通过"仅听写时在 foreground"缓解）。

### 工程约定
- `.xcodeproj` 被 gitignore，是 XcodeGen 生成物。**新增 `.swift` 后必须 `xcodegen generate` 再 `xcodebuild`**。
- 任何想固定的构建设置（Team / Bundle ID / 权限）都写进 `project.yml`，不要只在 Xcode 里手动改（generate 会覆盖）。
- 本地构建用：`xcodebuild -scheme VoiceMate -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual`（ad-hoc，仅验证编译）。用户正常 RUN 用 Xcode（Team 签名）。

### 提交 / 推送
- 本次改动已本地提交（见 git 历史）。
- **推送需用户在 GUI 终端执行**（无头 IDE 的 ssh-agent keychain 弹窗会卡住）：
  ```bash
  ssh-add --apple-use-keychain ~/.ssh/id_ed25519
  git push origin main
  ```
