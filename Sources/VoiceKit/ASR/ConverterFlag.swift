import Foundation

/// 在 AVAudioConverter 的 `@Sendable` input block 中安全传递标志位，
/// 避免 Swift 6 的 "mutation of captured var in concurrently-executing code" 警告。
final class ConverterFlag: @unchecked Sendable {
    var value = false
}
