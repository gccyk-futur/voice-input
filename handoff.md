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
**症状**：按热键后麦克风授权失败，日志末行 `[Coordinator] engine.start failed: microphoneNotAuthorized`，面板/ Dock "闪一下"后回到 accessory。app 进程没死（菜单栏图标还在），**不是崩溃**，是权限错误导致会话立即结束。

**已定位根因（高概率）**：TCC 隐私授权按**代码签名身份**绑定，不只看 Bundle ID。本会话内发生了：
- Bundle ID 从 `com.voicemate.VoiceMate` 改成 `me.ckai.VoiceMate`；
- Xcode 里选了 Team（签名从 ad-hoc 变 Team 签名）；
- 跑过 `CODE_SIGN_IDENTITY="-"` 的 ad-hoc 构建。
→ 系统设置里手动勾的授权挂在某**旧签名身份**上，当前 Xcode RUN 的实例签名对不上，永远 `.denied`。手动勾 ON 无效。

**下一步修复（按优先级）**：
1. 系统设置 → 麦克风 / 语音识别 → 把 `VoiceMate` 条目**关掉（toggle OFF，移除旧授权）**；旧的 `com.voicemate.VoiceMate` 条目一并删。
2. **彻底退出所有 VoiceMate 进程**（含菜单栏残留）。
3. **Xcode RUN**（Team 签名，别用 ad-hoc 命令）。
4. 按热键 → 系统**弹授权框** → 点「允许」。此时授权挂在当前运行签名上，必然生效。
   - 原理：代码里 `engine.start` 仅在 `.notDetermined` 才弹框；手动勾 ON 但签名不对仍是 `.denied` 不弹框。先 OFF 变回 `.notDetermined` → 弹框 → 授权给当前签名。
5. 若 OFF 后仍不弹框/仍 `.denied`：终端执行 `tccutil reset Microphone` + `tccutil reset SpeechRecognition`（先退出 app），再 RUN 必弹框。

**验证清单**：重新授权后 RUN，按 `Cmd+Shift+V`（轻点别按住）→ 应稳定显示面板并开始听写；`onPartial` 实时刷新；停止后自动粘贴到前台 app 光标处。

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
