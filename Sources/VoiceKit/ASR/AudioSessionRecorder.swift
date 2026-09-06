import Foundation
@preconcurrency import AVFAudio

/// 会话语音留档：把 ASR 引擎正在使用的 PCM 流旁路写成 AAC .m4a。
///
/// 为什么值得留：当「ASR 显示已连接但不出文字」时，用户无法区分是
/// **没录上**还是**识别丢了**。有了原始语音，回放即可定位环节；
/// 若识别丢了，还能用本机识别离线补一次（见 AudioRetranscriber）。
///
/// 实现：AVAudioFile 直接编码 AAC-LC 32kbps（≈0.24MB/分钟，语音存档足够清晰）。
/// 写入在专用串行队列异步进行，避免阻塞音频渲染线程；finish() 会排空队列再关文件。
final class AudioSessionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voicemate.audio-recorder")
    private let url: URL
    private var file: AVAudioFile?
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private var failed = false

    /// sourceFormat：即将被写入的 buffer 的格式（各引擎转换后的目标格式，通常 16k 单声道）。
    init?(url: URL, sourceFormat: AVAudioFormat) {
        self.url = url
        self.inputFormat = sourceFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: sourceFormat.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let audioFile = try AVAudioFile(forWriting: url, settings: settings)
            self.file = audioFile
            if audioFile.processingFormat == sourceFormat {
                self.converter = nil
            } else {
                self.converter = AVAudioConverter(from: sourceFormat, to: audioFile.processingFormat)
            }
            Log.info("[AudioRecorder] started: \(url.lastPathComponent), format=\(sourceFormat.sampleRate)Hz ch=\(sourceFormat.channelCount)")
        } catch {
            Log.error("[AudioRecorder] 创建录音文件失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 从音频 tap 线程调用：复制 buffer 后异步写入（buffer 生命周期仅限回调内，必须拷贝）。
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            self?.writeOnQueue(copy)
        }
    }

    /// 排空写入队列并关闭文件（幂等）。此后 write 调用被丢弃。
    func finish() {
        queue.sync {
            guard file != nil else { return }
            file = nil
            Log.info("[AudioRecorder] finished: \(url.lastPathComponent)")
        }
    }

    /// 取消：关闭并删除半成品文件（用户主动取消的会话不留档）。
    func cancel() {
        queue.sync { file = nil }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 私有

    private func writeOnQueue(_ buffer: AVAudioPCMBuffer) {
        guard let file, !failed else { return }
        do {
            if let converter {
                // 源格式 ≠ AAC 处理格式（如 int16 → float32）：先转换再写
                guard let out = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(
                        Double(buffer.frameLength)
                            * file.processingFormat.sampleRate / buffer.format.sampleRate + 64
                    )
                ) else { return }
                var error: NSError?
                let flag = ConverterFlag()
                converter.convert(to: out, error: &error) { _, status in
                    if flag.value { status.pointee = .noDataNow; return nil }
                    flag.value = true
                    status.pointee = .haveData
                    return buffer
                }
                guard error == nil, out.frameLength > 0 else { return }
                try file.write(from: out)
            } else {
                try file.write(from: buffer)
            }
        } catch {
            failed = true
            Log.error("[AudioRecorder] 写入失败（本次会话不再录制）: \(error.localizedDescription)")
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let src = buffer.audioBufferList.pointee
        let dst = copy.audioBufferList.pointee
        memcpy(dst.mBuffers.mData, src.mBuffers.mData, Int(src.mBuffers.mDataByteSize))
        return copy
    }
}
