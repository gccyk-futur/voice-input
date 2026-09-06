import Foundation
import AVFoundation

/// 历史语音回放：单例管理一个 AVAudioPlayer，同一时间只播一段。
/// playingFile 供行 UI 显示 播放/停止 状态。
@MainActor
@Observable
final class AudioPlaybackController: NSObject {
    static let shared = AudioPlaybackController()

    /// 正在播放的留档文件名；nil 表示空闲。
    private(set) var playingFile: String?

    private var player: AVAudioPlayer?

    func toggle(file: String) {
        if playingFile == file {
            stop()
            return
        }
        play(file: file)
    }

    func play(file: String) {
        stop()
        guard let url = AudioLibrary.url(forFile: file),
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playingFile = file
        } catch {
            Log.error("[Playback] 播放失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingFile = nil
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 单例同一时刻只播一段，自然结束即复位（无需比对 player 实例，避开跨隔离域捕获）
        Task { @MainActor in
            self.stop()
        }
    }
}
