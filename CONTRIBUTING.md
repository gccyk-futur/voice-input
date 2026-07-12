# 贡献指南

VoiceKit 欢迎 Issue 和 PR。由于这是一个个人维护的项目，请遵循以下约定。

## 报告 Bug

1. 先在 [Issues](../../issues) 中搜索是否已有相同问题
2. 提交时请包含：macOS 版本、VoiceKit 版本、复现步骤、预期行为 vs 实际行为
3. 不要包含 API Key 等敏感信息

## 提交 PR

1. Fork 仓库，创建功能分支
2. 遵循现有代码风格：Swift 6 严格并发、中文注释、不用第三方依赖
3. 确保 `xcodegen generate && xcodebuild -scheme VoiceKit -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual` 编译通过
4. PR 标题简明描述改动，正文说明动机和方案

## 代码风格

- Swift 6 strict concurrency
- `@MainActor` 标注 UI 相关代码
- 协议抽象所有可插拔模块
- 仅使用 Apple 系统框架，不引入第三方依赖
- 注释解释 WHY，而非 WHAT

## 在你开始之前

较大改动请先提 Issue 讨论，避免浪费精力。VoiceKit 的设计原则是**保持简单、零依赖、不需要注册账号**。
