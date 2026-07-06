# VoiceMate 开发交接备忘录

> 更新：2026-07-07
> 状态：核心功能已完成并推送（HEAD = a0ed5f7）。功能完善第一轮已落地（待推送）。

---

## 已完成（第一阶段：核心链路，commit 1e05c10 / a0ed5f7）

- 自动激活链路：`FloatingPanelController.clickToActivate()` 模拟点击触发 WindowServer 级激活 + `AppCoordinator.scheduleActivationPersistence`
- 文本累计：`SystemDictationEngine` CMTimeRange 有序 `[Segment]` 数组（committed/pending 用 `filter`）
- 粘贴：`PasteService` AX 直插 → 写剪贴板 + HID ⌘V → PID 直送
- 状态机：无法再次呼出 / 停止不进光标已修复

## 功能完善（本轮，待推送）

- **历史记录窗口**：`HistoryView` + `HistoryWindowController`，状态栏新增「历史记录…」入口；支持浏览 / 复制 / 收藏 / 删除 / 清空，实时跟随 `HistoryStore`（didChange 通知）
- **登录时启动**：补齐 Settings 里 `launchAtStartup` 开关的真实逻辑（`SMAppService.mainApp`，见 `LoginItemManager`）；`AppDelegate` 启动 + `ConfigStore.update` 双触发同步
- **Claude 引擎**：补全 `LLMClaudeConfig` 对应的 `ClaudeEngine`（Anthropic Messages API 流式），接入 `resolveLLM` 与设置 Picker

## 已知限制 / 待办

- 听写期间 Dock 图标短暂显示（`TransformProcessType` 副作用）
- `throwing -10877` + locale 警告：非致命，首次约 1s 冷启动
- iTerm2 等终端 app 极端情况激活仍可能不稳定
- OpenAI / DeepSeek 引擎 `baseUrl` 的 path 被 `/chat/completions` 覆盖（丢失 `/v1`），待修
- 运行期 AX 授权需 Xcode Run（Automatic 签名）；ad-hoc 签名仅供编译，会导致粘贴回退剪贴板

## 测试清单

1. Xcode Run（⌘R）启动，确认 AX 权限 `isTrusted=true`、状态栏可见
2. 状态栏「历史记录…」打开窗口，确认粘贴后新增条目、复制/收藏/删除/清空可用
3. 设置开启「登录时启动」，重启后确认自动启动（首次会弹系统授权框）
4. 设置选 Claude 并填 key，确认润色可流式返回
