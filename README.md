# VoiceMate

macOS 语音输入助手——全局热键呼出，说话即转文字，自动粘贴到当前光标。

## 功能

- **全局热键**（默认 `Cmd+Shift+V`）：任意 app 中呼出悬浮面板
- **实时语音识别**：边说边出字，说完自动粘贴
- **双引擎**：
  - 系统听写（离线免费，macOS 内置）
  - 阿里云 Fun-ASR（在线高精度，自动标点）
- **静音自动停止**：说完停顿几秒自动结束，不用再按热键
- **AI 润色**：接入 LLM（通义千问 / OpenAI / DeepSeek / Claude / Ollama），口语转书面语
- **历史记录**：所有识别结果可回溯

## 环境要求

- macOS 26+
- Xcode 16+

## 快速开始

```bash
git clone https://github.com/yourname/VoiceMate.git
cd VoiceMate
xcodegen generate
open VoiceMate.xcodeproj
```

### 配置

复制示例配置到 `~/Library/Application Support/VoiceMate/config.json`：

```bash
mkdir -p ~/Library/Application\ Support/VoiceMate
cp config.example.json ~/Library/Application\ Support/VoiceMate/config.json
```

启动后在菜单栏 VoiceMate → 设置 中配置引擎和 API Key。

## 引擎

| 引擎 | 类型 | 特点 |
|------|------|------|
| 系统听写 | 本地离线 | 免费，macOS 内置，不抢焦点 |
| 阿里云 Fun-ASR | 在线 WebSocket | 高精度，自动标点，不抢焦点 |

## 架构

```
VoiceMate/
├── ASR/              # 语音识别引擎
│   ├── ASREngine.swift
│   ├── SystemDictationEngine.swift
│   ├── LegacyDictationEngine.swift
│   └── AlibabaASREngine.swift
├── LLM/              # 大模型润色
│   ├── LLMEngine.swift
│   ├── OpenAICompatibleEngine.swift
│   ├── ClaudeEngine.swift
│   ├── OllamaEngine.swift
│   └── StreamingClient.swift
├── Panel/            # 悬浮面板
│   ├── FloatingPanelController.swift
│   └── PanelView.swift
├── Hotkey/           # 全局热键
│   ├── HotkeyManager.swift
│   └── HotkeyRecorder.swift
├── Paste/            # 粘贴回写
│   └── PasteService.swift
├── Config/           # 配置持久化
│   ├── AppConfig.swift
│   └── ConfigStore.swift
├── History/          # 历史记录
├── Settings/         # 设置界面
├── Coordinator/      # 应用中枢
├── Prompt/           # 提示词模板
└── App/              # 应用入口
```

## 构建

```bash
# 命令行 ad-hoc 构建（仅验证编译）
xcodebuild -scheme VoiceMate -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual

# 正常开发用 Xcode CMD+R（自动签名）
```

## License

MIT
