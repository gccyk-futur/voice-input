# 隐私说明

最后更新：2026 年 9 月 5 日（对应 2.1.0）

## 我们收集什么

**不向任何地方上传。** VoiceKit 没有后台服务器，不使用任何分析或追踪框架，不会把语音、文字或使用数据发送给作者或第三方。

下表中的文件全部只存在于你自己的 Mac 上。其中「使用统计」用于在应用内向你展示使用情况，
默认开启、可随时在「设置 → 历史与数据」中关闭，在「设置 → 数据隐私」中查看、导出或清空。

## 数据存储在哪

所有数据仅存储在你的 Mac 本地：

| 数据 | 位置 | 说明 |
|------|------|------|
| 配置（含 API Key、词汇纠正规则） | `~/Library/Application Support/VoiceMate/config.json` | JSON 明文，仅本机用户有读取权限；词汇纠正规则存于其中 `asr.correction` 字段 |
| 历史记录 | `~/Library/Application Support/VoiceMate/history.json` | 最近若干条识别原文与润色结果 |
| 速插快照 | `~/Library/Application Support/VoiceMate/snapshots.json` | 你手动保存、可反复速插的文本片段，不会自动清理 |
| 语音留档 | `~/Library/Application Support/VoiceMate/audio/` | 每条历史可附带当时的录音（AAC），仅在你开启后保存；删除或清空历史时一并删除，可在「设置 → 历史与数据」关闭 |
| 词云快照 | `~/Library/Application Support/VoiceMate/wordcloud/` | 用词频率的时间切片，只含词和次数，**不含原文**；功能默认关闭，需在设置中手动开启 |
| 运行日志 | `~/Library/Logs/VoiceKit/voicekit.log` | 用于排查问题，**含转录原文**；超过 2MB 自动覆盖较早内容 |
| 使用统计 | `~/Library/Application Support/VoiceMate/stats.jsonl` | 仅时长、字数、引擎、耗时等元数据，**不含任何文字内容**；可在设置中关闭 |
| Keychain | 未使用 | API Key 直接存于 config.json，不经过 macOS Keychain |

以上每一项的位置与占用大小，都可在「设置 → 数据隐私」页中查看、显示所在目录或清空。

App Store 版运行在沙盒中，上述文件位于应用自己的容器目录内，路径结构相同。

## 语音和文字的去向

取决于你选择的识别引擎：

- **系统听写**：音频送往 Apple 服务器进行识别（macOS 内置服务的正常行为）。Apple 的隐私政策适用于此数据。
- **阿里云 Fun-ASR**：音频通过 WebSocket 发往你**自己的**阿里云账号。
- **讯飞听写**：音频通过 WebSocket 发往你**自己的**讯飞开放平台账号。
- **Deepgram**：音频发往你**自己的** Deepgram 账号。
- **AI 润色**：识别后的文字发往你配置的 AI 服务。如果使用 Ollama 本地模型，文字完全不出电脑。

三个云端识别引擎与 AI 润色均为**自带密钥（BYOK）**接入 —— 用的是你自己的账号，你是数据的控制者。未配置密钥的引擎不会被使用，会自动回退到系统听写。VoiceKit 仅建立连接和传输数据，不缓存、不记录这些通信内容。

## 权限

VoiceKit 请求以下系统权限，全部用于核心功能：

| 权限 | 用途 |
|------|------|
| 麦克风 | 录音 |
| 语音识别 | 将语音转为文字 |
| 辅助功能（可选） | 识别完成后自动粘贴到输入框 |

所有权限均可随时在「系统设置 → 隐私与安全性」中撤销。

## 第三方服务

当你使用阿里云、讯飞、Deepgram 任一云端识别引擎，或第三方 AI 润色服务时，你与这些服务商的交互受其各自的隐私政策约束。VoiceKit 仅作为数据传输管道。

## 联系

如有隐私相关问题：gccyk2000@gmail.com

线上版本：<https://ckai.me/voice-kit/privacy.html>
