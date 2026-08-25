---
name: voicekit
description: 引导用户配置与排障 VoiceKit（macOS 语音输入工具）：config.json 完整 schema、字段含义、常见错误对照、损坏修复。当用户说"不会设置 VoiceKit / 语音输入不工作 / AI 润色连不上 / 配置丢了"时使用。
---

# VoiceKit 配置引导与排障

> 适用版本：VoiceKit ≥ 1.2.0（2026-08，含提示词预设库与配置三层防御）。
> 本文件与 `Sources/VoiceKit/Config/AppConfig.swift` 同仓版本化；schema 变更必须同 commit 更新本文件。

VoiceKit 是纯离线客户端（BYOK），无后台服务器。你的任务：引导用户把"四个引擎之一的凭据"或"AI 润色模型"配好，或在配置出问题时修复现场。

## 一、关键路径

| 内容 | 位置 |
|---|---|
| 主配置 | `~/Library/Application Support/VoiceMate/config.json` |
| 自动备份 | 同目录 `config.backup.json`（每次保存成功时同步写入） |
| 损坏隔离 | 同目录 `config.corrupt-<时间戳>.json`（主备都解不开时保留现场，**绝不删除**） |
| 历史/快照 | 同目录 `history.json` / `snapshots.json` |
| UI 偏好（不进 config.json） | UserDefaults 域 `me.ckai.VoiceMate` |

**热重载**：app 运行中监听 config.json，合法修改会自动生效并刷新 UI；改坏了会通知用户并保留旧配置。**改完不必重启**（但权限类变更除外，见决策树）。

## 二、操作纪律（给 AI）

1. 改前先复制一份：`cp config.json /tmp/voicekit-config-<date>.bak`（即使 app 有自己的备份，也留一份你看得见的）。
2. 改后必须 `python3 -m json.tool` 校验，再让 app 热重载。
3. 只改用户要求改的字段；不要"顺手优化"其他配置。
4. API Key 是明文存储的，**不要把 config.json 内容发到任何外部服务**。
5. `llm.prompts[]` 里带 `builtinID`/`builtinVersion` 的是从内置预设库导入的拷贝：正文没被用户改过时，版本升级会自动跟随库更新；用户改过正文则不再浮动。不要手动改这两个字段。

## 三、config.json schema

```json
{
  "version": "1.0",
  "general": { ... },
  "asr": { ... },
  "llm": { ... }
}
```

### general

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| hotkey | string | `"Cmd+Shift+V"` | 主热键（开始/停止听写） |
| quickInsertHotkey | string | `"Cmd+Shift+I"` | 速插面板热键 |
| launchAtStartup | bool | false | 开机启动 |
| showSettingsOnLaunch | bool | true | 启动时显示设置 |
| windowStyle | string | `"vibrancy"` | 面板材质 |
| maxHistoryCount | int | 50 | 历史上限，**不超过 10000** |
| usageStatsEnabled | bool | true | 本地使用统计 |
| clipboardRetentionSeconds | double | 0 | 手动 ⌘V 场景下识别文字在剪贴板保留时长，0=不还原 |
| sound | object | 见下 | 提示音：enabled / startEnabled / stopEnabled / startSound / stopSound |

### asr —— 语音识别

| 字段 | 说明 |
|---|---|
| engine | `system`（macOS 听写，免费零配置）/ `aliyun` / `xunfei` / `deepgram` |
| system.language | 如 `zh-Hans-CN`、`en-US` |
| system.silenceAutoStopEnabled / silenceTimeout | 停顿自动结束（秒） |
| aliyun.apiKey / workspaceId | 阿里云百炼凭据，**两者必填** |
| aliyun.region / model | `cn-beijing` / `fun-asr-realtime` |
| aliyun.semanticPunctuation | 语义标点 |
| aliyun.speechNoiseThreshold / maxSentenceSilence | VAD 灵敏度 0.0–1.0 / 句尾静音毫秒 |
| xunfei.appId / apiKey / apiSecret | 讯飞凭据，**三个必填** |
| deepgram.apiKey / model | 如 `nova-3` |
| *.autoStopEnabled / autoStopTimeout | 长静音自动结束（默认 5 秒） |

所选引擎凭据不全时自动回退系统听写——**不会报错失败**，用户疑惑"为什么识别变了"时先查这里。

### llm —— AI 润色

| 字段 | 说明 |
|---|---|
| enabled | 总开关 |
| models[] | 模型列表：`id`(UUID) / `name` / `engine`(`openai`\|`ollama`) / `baseUrl` / `apiKey` / `model`；`totalTokens`、`usageCount` 是统计字段，别手改 |
| selectedModelID | 当前模型，必须命中 models[].id |
| temperature | 0.0–1.0 |
| prompt.system / prompt.user | 「默认」提示词；user 模板里 `{{input}}` 是转写文本占位符 |
| prompts[] | 自定义/已导入预设：`id` / `name` / `system` / `user` / `builtinID` / `builtinVersion` |
| selectedPromptID | 空字符串 = 用「默认」提示词 |

云端模型 baseUrl 例：`https://api.openai.com/v1`、`https://api.deepseek.com/v1`；Ollama：`http://localhost:11434`。

### UserDefaults（`defaults read me.ckai.VoiceMate <key>`）

| key | 值 | 说明 |
|---|---|---|
| voicekit.ui.language | `""` 或 `zh-Hans`/`en` 等 | UI 语言，空=跟随系统 |
| voicekit.ui.appearance | system/light/dark | 外观 |
| voicekit.ui.textScale | system/larger 等 | 文字大小 |
| voicekit.promptUpgrade.defaultPolish.v2 | bool | 默认提示词升级询问已问过（勿动） |

## 四、决策树：用户说 X → 你做 Y

- **"不知道怎么开始"** → 确认三项权限（麦克风/语音识别/辅助功能，系统设置→隐私与安全性）→ 默认引擎 system 即可用，按下 hotkey 说话。
- **"想要更准的中文识别"** → 引导开通阿里云百炼 → 填 aliyun.apiKey + workspaceId → engine 改 `aliyun`。
- **"想要润色"** → 选一个模型（有云端 key 用 openai 协议；注重隐私用本机 Ollama）→ 填 models[] + selectedModelID → enabled=true → 提示词先用默认，熟悉后再从预设库导入。
- **"热键没反应"** → 辅助功能权限；**刚授权必须重启 VoiceKit 一次**（macOS 权限缓存）。
- **"识别结果跑到别的语言了"** → 查 asr.system.language，或是否误切了引擎。
- **"润色输出变成了翻译/语言不对"** → 查 selectedPromptID 指向的 prompts[].name；本地小模型对中英混排稳定性有限，换更强模型。
- **"粘贴出现两遍文字（Chrome 等）"** → 让目标 app 退出重开（其 AX 接口状态异常），不是 VoiceKit 录了两次。
- **"配置被重置了/弹了恢复提示"** → 走第五章。

## 五、常见损坏模式与修复（对接隔离文件）

启动时若弹"配置损坏"提示，说明主备都解不开，坏文件已隔离为 `config.corrupt-*.json`：

1. **JSON 语法错**（手改留了尾逗号/少了引号）：用 `python3 -m json.tool` 定位，修好后放回 config.json。
2. **类型错**（把字符串写成数字等）：对照第三章表改回正确类型；缺字段没关系，解码有默认值。
3. **只想救回 API Key**：从隔离文件里 grep `apiKey`，把值抄进新配置对应字段即可，其余用默认。
4. 修不动就让用户在 设置→历史与数据 里「重置为默认」，再按决策树重配。

## 六、参考

- 用户使用说明书（含图文）：https://ckai.me/voice-kit/help.html
- schema 源头：`Sources/VoiceKit/Config/AppConfig.swift`（以代码为准，本文件滞后时信代码）
