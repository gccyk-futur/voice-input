# Changelog

## 1.0.0 (build 28) — 2026-07-18

修复 App Store 审核拒绝（Guideline 2.1(a) / 5.1.1(iv)），并修复官网版沙盒导致的粘贴失效。

### 权限
- 权限页按钮直接触发系统授权弹窗（此前只跳转系统设置，语音识别因此从不出现授权请求、设置列表中也没有本 App）
- 权限状态实时刷新：系统弹窗完成或从系统设置返回 App 后立即更新（此前授权后界面仍显示「未授权」）
- 按审核要求，授权前按钮文案改为「继续」；已被拒绝时显示「打开系统设置」
- 修复点击「继续」后权限回调触发线程隔离断言导致的崩溃（EXC_BAD_INSTRUCTION）
- 官网版辅助功能卡片同样改为触发系统授权提示，App 自动进入辅助功能列表（此前只能手动点「+」添加）

### 官网版
- 移除 App Sandbox（entitlements 拆分为 VoiceMate-Direct.entitlements）：此前官网版与 App Store 版共用沙盒权限清单，导致辅助功能状态假阳性「已授权」、Accessibility 直插与模拟 ⌘V 在真实用户机器上静默失效。App Store 版保持沙盒不变（build-appstore.sh 显式指定）
- 注意：移除沙盒后配置/历史存储路径变更（~/Library/Application Support/VoiceMate），需重新配置一次

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
