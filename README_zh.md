# VoiceKit 语音输入助手

[English](README.md) | 中文

macOS 语音输入助手 — 全局热键呼出，说话即转文字，自动粘贴到当前光标。

**下载**: [GitHub Releases](https://github.com/gccyk-futur/voice-input/releases)

## 功能

- **全局热键**（默认 `Cmd+Shift+V`）：任意 app 中呼出悬浮面板
- **实时语音识别**：边说边出字，说完自动粘贴
- **四引擎语音识别**（在设置中选择，云端引擎均自带密钥 BYOK）：
  - 系统听写（离线免费，macOS 内置）
  - 阿里云 Fun-ASR（在线高精度，自动标点）
  - 讯飞听写（在线流式，动态纠错）
  - Deepgram（在线流式，低延迟）
  - 未配置凭据的引擎自动回退到系统听写
- **静音自动停止**：说完停顿几秒自动结束
- **AI 润色**：接入 LLM（OpenAI / DeepSeek / Claude / Ollama），口语转书面语
- **历史记录**：所有识别结果可回溯

## 多语言

界面跟随 macOS 系统设置中的首选语言。目前支持：

- 简体中文
- 繁体中文
- English
- 日本語
- 한국어
- Français
- Deutsch
- Español
- Português (Brasil)
- Italiano

未覆盖的系统语言会自动回退到英文，不包含俄语。

## 数据流向

VoiceKit 是一个**纯客户端工具**，没有后台服务器，不收集任何数据。

| 引擎 | 数据去哪了 |
|------|-----------|
| 系统听写 | 语音由 macOS 内置引擎在**本地**处理，不出设备 |
| 阿里云 Fun-ASR | 语音直接发送到**你自己的阿里云账号**，不经过任何中间服务器 |
| 讯飞听写 | 语音直接发送到**你自己的讯飞开放平台账号** |
| Deepgram | 语音直接发送到**你自己的 Deepgram 账号** |
| AI 润色 | 文本直接发送到**你配置的 AI 服务**（OpenAI / DeepSeek / Ollama 等）。如使用 Ollama 本地模型，数据完全不出电脑 |

- **不上传**：VoiceKit 没有服务端，不收集使用数据、不追踪用户行为
- **本地存储**：API Key 和配置保存在 `~/Library/Application Support/VoiceMate/`，仅你本机可访问
- **隐私清单**：已包含 `PrivacyInfo.xcprivacy`，App Store 合规

## 环境要求

- macOS 14+
- Xcode 16+（仅开发者构建需要）

## 开发构建

> 普通用户请直接下载安装，无需构建。

```bash
git clone https://github.com/gccyk-futur/voice-input.git
cd voice-input
xcodegen generate
open VoiceKit.xcodeproj
```

配置：复制 `config.example.json` 到 `~/Library/Application Support/VoiceMate/config.json`，然后在 App 的设置界面中填入 API Key。

维护者使用 1Password CLI (`op read`) 管理签名证书和密钥，详见 `scripts/`。贡献者构建时使用 Xcode 自动签名即可，无需额外配置。

## 架构

```
VoiceKit/
├── Sources/VoiceKit/
│   ├── ASR/              # 语音识别引擎（系统听写 / 阿里云 Fun-ASR / 讯飞 / Deepgram）
│   ├── LLM/              # 大模型润色（OpenAI / DeepSeek / Ollama）
│   ├── Panel/            # 悬浮面板（NSPanel + 毛玻璃）
│   ├── Hotkey/           # 全局热键（Carbon + NSEvent 双引擎）
│   ├── Paste/            # 粘贴回写（Accessibility API + 剪贴板回退）
│   ├── Config/           # 配置持久化
│   ├── History/          # 历史记录
│   ├── Settings/         # 设置界面
│   ├── Coordinator/      # 应用中枢 + 状态机
│   ├── Prompt/           # 提示词模板
│   └── App/              # 应用入口
├── docs/                 # 技术文档
├── scripts/              # 构建脚本（维护者用）
├── project.yml           # xcodegen 工程定义
└── config.example.json   # 配置模板
```

## 技术栈

零外部依赖。Swift 6 严格并发。纯 Apple 框架。

## License

MIT
