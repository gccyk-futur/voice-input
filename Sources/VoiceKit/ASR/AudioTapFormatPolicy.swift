/// Policy for installing an AVAudioEngine input tap.
///
/// Passing a non-nil format asks AVAudioEngine to apply that format to the
/// node's output bus. After a device route change, the previously observed
/// hardware format may no longer be the format the node can expose.
enum AudioTapFormatPolicy {
    /// Let AVAudioEngine use the input node's current native output format.
    static let usesNodeOutputFormat = true
}
