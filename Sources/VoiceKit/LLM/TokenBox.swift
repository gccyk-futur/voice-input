import Foundation

/// 用于在 Sendable 闭包中传递 token 统计（绕开 Swift 6 严格并发对 self 的捕获限制）
final class TokenBox: @unchecked Sendable {
    var prompt: Int = 0
    var completion: Int = 0
}
