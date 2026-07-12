# 安全策略

## 报告漏洞

如果你发现安全漏洞，请**不要**提交公开 Issue。请发送邮件到 gccyk2000@gmail.com，我会在 48 小时内回复。

## 安全设计

VoiceKit 是一个纯客户端 macOS 应用，设计原则：

- **无服务端**：不连接任何 VoiceKit 所属的服务器，所有网络请求仅在你主动配置第三方服务时发生
- **本地存储**：API Key 和配置以明文 JSON 存储在 `~/Library/Application Support/VoiceKit/config.json`，仅本机用户可读
- **不上传数据**：不收集崩溃报告、使用统计、用户行为数据
- **不依赖第三方 SDK**：仅使用 Apple 系统框架（AppKit、SwiftUI、AVFoundation、Speech 等），零外部依赖

## 网络请求

VoiceKit 仅在以下场景发起网络请求，且目标地址全部由你配置：

| 场景 | 目标 | 触发条件 |
|------|------|---------|
| 阿里云 Fun-ASR 语音识别 | `wss://<workspace>.<region>.maas.aliyuncs.com` | 选择阿里云引擎并使用 |
| AI 润色 | 你配置的 Base URL（OpenAI / DeepSeek / Ollama 等） | 开启润色功能并使用 |

不使用阿里云引擎且不开启润色时，VoiceKit 完全离线运行。

## 支持的版本

仅最新发布版本。历史版本不提供安全补丁。
