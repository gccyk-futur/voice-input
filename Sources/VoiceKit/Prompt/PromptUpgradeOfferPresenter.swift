import AppKit

extension PromptUpgradeOffer {
    /// 启动末尾调用；配置恢复弹窗优先，不叠弹。
    static func presentIfNeeded() {
        Task { @MainActor in
            guard ConfigStore.shared.recoveryState == .none else { return }
            let alreadyOffered = UserDefaults.standard.bool(forKey: offeredKey)
            guard shouldOffer(
                config: ConfigStore.shared.config,
                alreadyOffered: alreadyOffered,
                legacySystems: LegacyFactoryPolishPrompt.legacySystems()
            ) else { return }

            // 无论选择什么都只问一次
            UserDefaults.standard.set(true, forKey: offeredKey)

            let alert = NSAlert()
            alert.messageText = VoiceKitLocalization.string("默认提示词已改进")
            alert.informativeText = VoiceKitLocalization.string("新版默认提示词更中性：只清理口语、不强行书面化，并跟随输入语言输出。仅在检测到你仍在使用旧出厂默认时询问一次；自定义内容不受影响。是否替换？")
            alert.addButton(withTitle: VoiceKitLocalization.string("替换为新默认"))
            alert.addButton(withTitle: VoiceKitLocalization.string("保留当前"))
            if alert.runModal() == .alertFirstButtonReturn {
                var cfg = ConfigStore.shared.config
                cfg.llm.prompt = LLMPromptConfig()
                ConfigStore.shared.update(cfg)
            }
        }
    }
}
