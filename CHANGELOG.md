# Changelog

## 1.0.0 (build 13) — 2026-07-12

首个正式版本，已上架 App Store。

### 语音识别
- 系统听写：macOS 内置引擎，离线免费，支持中英日韩法德西葡俄意
- 阿里云 Fun-ASR：在线 WebSocket 引擎，高精度，自动标点
- 引擎运行时切换，无需重启
- 静音自动停止（可配置阈值和超时时间）

### AI 润色
- 支持 OpenAI、DeepSeek、Claude、Ollama 及任何 OpenAI 兼容 API
- 流式逐 token 返回，实时显示
- 多模型管理，可自由增删切换
- 自定义系统提示词和用户模板
- 批量连接测试

### 交互
- 全局热键（Carbon + NSEvent 双引擎，沙盒/非沙盒自动适配）
- 悬浮毛玻璃面板（NSPanel + NSVisualEffectView）
- 自动粘贴（Accessibility API 直插 + 剪贴板回退）
- 菜单栏图标自动恢复（定时巡检 + 系统事件监听）

### 设置
- 热键录制控件（键盘捕获，防非法输入）
- 音效自定义（系统内置声音）
- 权限状态一览（麦克风/语音识别/辅助功能）
- 数据流向说明（关于页面）
- 登录时自动启动

### 工程
- 零外部依赖，纯 Apple 框架
- Swift 6 严格并发
- xcodegen 文本化工程定义
- 隐私清单（PrivacyInfo.xcprivacy）
- Universal 架构（arm64 + x86_64）
- DMG 独立分发 + App Store 双渠道
