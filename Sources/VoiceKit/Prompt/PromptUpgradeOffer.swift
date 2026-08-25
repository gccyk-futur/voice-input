/// 默认提示词升级询问（一次性）：检测到用户仍在使用旧版出厂默认提示词时，
/// 首次启动询问是否替换为新默认；无论选什么都只问一次。
/// 原则：升级不静默改写用户配置，改进以「提供选择」的方式送达。
/// 弹窗部分在 PromptUpgradeOfferPresenter.swift（依赖 ConfigStore/NSAlert，不进测试 target）。
enum PromptUpgradeOffer {
    static let offeredKey = "voicekit.promptUpgrade.defaultPolish.v2"

    /// 检测条件（纯逻辑，供单测）：仍在使用旧版出厂默认（任一语言逐字相等）。
    static func shouldOffer(config: AppConfig, alreadyOffered: Bool, legacySystems: [String]) -> Bool {
        guard !alreadyOffered else { return false }
        return legacySystems.contains(config.llm.prompt.system)
    }
}
