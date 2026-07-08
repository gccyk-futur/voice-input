# VoiceMate 开发交接备忘录

> 本文件由人工在下班 / 交接时更新；开发过程不在此记录，进展见 git 历史。

## 当前状态（2026-07-08）

### 本次会话完成

1. **应用图标修复**：`Info.plist` + `project.yml` 增加 `CFBundleIconFile: AppIcon`，图标正常显示。
2. **macOS 14 兼容性修复**：`LSUIElement: true`；移除手动 `setActivationPolicy(.accessory)`；`FloatingPanelController.show()` 加 `NSApp.activate`。
3. **粘贴简化**：`PasteService` 统一用 `postToPid` 发 Cmd+V，移除 HID/AX 杂项。macOS 26 可靠，14 若失败文字在剪贴板。
4. **LLM 引擎精简**：从 5 个引擎简化为 2 个——OpenAI 协议（覆盖 OpenAI / DeepSeek / 阿里百炼 / Groq 等）+ Ollama 本地。
5. **设置页面全面重做**：
   - 左对齐排版，标签在上方、控件在下方
   - 常规 tab：声音选择（系统声音列表）、权限状态面板（麦克风/语音识别/辅助功能 + 刷新按钮 + 打开设置按钮）
   - ASR tab：引擎/语言固定位置不跳动；阿里云参数均有说明文字
   - LLM tab：未启用时字段灰显不隐藏；API Key / Base URL 等排版固定不跳动；温度有说明；thinking 模式有说明；提示词预览 Sheet；润色效果测试 Sheet
   - 保存校验：阿里云 API Key/Workspace ID 非空；LLM Base URL/API Key/Model 非空
6. **启动行为**：配置项 `showSettingsOnLaunch`（默认 true），双击启动显示设置窗口；开机自启不弹设置。
7. **状态栏菜单重做**：状态区（引擎名称、阿里云 WS 连接灯、AI 润色开关）+ 操作区（历史/设置/退出）。
8. **打包脚本**：`scripts/build-release.sh`（签名 + 构建 Release）+ `scripts/setup-notary.sh`（公证凭证）。`project.yml` 中 Release 配置使用 `Developer ID Application` 手动签名。
9. **本地引擎静音检测**：`LegacyDictationEngine` 加入 RMS 静音检测逻辑，默认关闭（本地引擎计算不准）。阿里云引擎 VAD 不受影响。
10. **自动停止保护期**：引擎启动后 1 秒内不触发静音检测。

### macOS 版本兼容性

| 功能 | macOS 14 | macOS 26 |
|------|----------|----------|
| 系统听写（SFSpeechRecognizer） | ✅ LegacyDictationEngine | ✅ |
| 本地连续听写（SpeechAnalyzer） | ❌ API 不存在 | ✅ SystemDictationEngine |
| 粘贴回写（postToPid） | ⚠️ 可能被丢弃，需辅助功能 | ✅ |
| 阿里云 Fun-ASR | ✅ WebSocket | ✅ |
| Ollama / OpenAI 润色 | ✅ | ✅ |

### 已知待办
- macOS 14 上 `CGEventPostToPid` 粘贴可能不工作，授权辅助功能后可解决（AX/HID 级别发 Cmd+V）。
- TRAE / VS Code 等 Electron 应用可能不处理 postToPid 键盘事件（需授权辅助功能后用 HID 级别事件）。
- 阿里云 WS 连接启动延迟：首次按热键才建连，前 1-2 秒语音可能丢失。

### 工程约定
- `.xcodeproj` 被 gitignore，是 XcodeGen 生成物。**修改代码后必须 `xcodegen generate`**。
- 构建设置写 `project.yml`，不要只在 Xcode 手动改。
- 打包命令：
  ```bash
  xcodegen generate
  xcodebuild -target VoiceMate -configuration Release \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=Developer ID Application: Kai Meng (F2J85LVHS4)" \
    DEVELOPMENT_TEAM=F2J85LVHS4 \
    "OTHER_CODE_SIGN_FLAGS=--timestamp --options=runtime" \
    build
  ```
  输出：`build/Release/VoiceMate.app`
- 公证 DMG：`./scripts/setup-notary.sh`（仅一次），然后 `./scripts/build-release.sh`。

### 配置结构

```
~/Library/Application Support/VoiceMate/config.json
```

默认值硬编码在 `AppConfig.swift`。设置页面保存时写入；外部编辑可热重载（文件监听）。
