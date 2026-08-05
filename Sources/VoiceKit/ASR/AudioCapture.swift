import Foundation
@preconcurrency import AVFAudio
import CoreAudio

/// 静音自动停止配置。
struct SilenceConfig: Sendable {
    /// RMS 低于该阈值视为静音（硬件 float32 原始值，通常 0.01~0.03）。
    var threshold: Float
    /// 持续静音多久后触发 onAutoStop。
    var timeout: TimeInterval
    /// 启动后宽限期：这段时间内不计静音，避免刚启动就被误判。
    var gracePeriod: TimeInterval
}

/// 统一的麦克风采集组件：三个 ASR 引擎共用，集中处理所有容易踩坑的环节。
///
/// 职责：
/// 1. 起飞前预检：默认输入设备存在、硬件采样率/声道合法（无麦时 sampleRate=0 → 抛错，不闪退）。
/// 2. NSException 桥接：installTap / removeTap / engine.start 都可能抛 ObjC 异常，
///    Swift 的 do/catch 接不住，必须经 NSExceptionCatcher 转成 Swift.Error。
/// 3. 重采样到引擎要求的 targetFormat。
/// 4. RMS 电平回调 + 静音自动停止（带启动宽限期）。
/// 5. 幂等 stop：用 tapInstalled 守卫，避免"没装 tap 就 removeTap"二次崩溃。
///
/// 不做路由变化监听（P1）：录音中设备切换暂不处理，当前仅保证起飞前/降落不崩。
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var tapInstalled = false
    private var silenceStart: Date?

    /// 执行可能抛 NSException 的代码，返回 Swift.Error（来自桥接的 NSError）；
    /// 正常返回 nil。ObjC 的 `BOOL...error:` 被 Swift 导入为 `throws`。
    private static func guarded(_ block: () -> Void) -> Error? {
        do {
            try NSExceptionCatcher.catchException(block)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 启动

    func start(targetFormat: AVAudioFormat,
               bufferSize: AVAudioFrameCount = 1024,
               silence: SilenceConfig? = nil,
               onLevel: (@Sendable (Float) -> Void)? = nil,
               onAutoStop: (@Sendable () -> Bool)? = nil,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        // ① 设备预检：CoreAudio 确认默认输入设备存在
        guard Self.hasDefaultInputDevice() else {
            throw ASRError.noInputDevice
        }
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        // 无可用输入时硬件格式为 sampleRate=0/channelCount=0，installTap 必抛 NSException
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw ASRError.noInputDevice
        }
        // ② 格式转换器
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw ASRError.converterInit
        }

        lock.withLock { self.silenceStart = nil }
        let startTime = Date()
        // 在 tap block 内只读这些常量，避免并发读写可变状态
        let levelCB = onLevel
        let autoStopCB = onAutoStop
        let silenceCfg = silence

        // ③ 安装 tap（桥接 NSException）
        if let err = Self.guarded({
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
                [weak self] buffer, _ in
                self?.processBuffer(
                    buffer,
                    hardwareFormat: hardwareFormat,
                    targetFormat: targetFormat,
                    converter: converter,
                    startTime: startTime,
                    silence: silenceCfg,
                    onLevel: levelCB,
                    onAutoStop: autoStopCB,
                    onBuffer: onBuffer
                )
            }
        }) {
            throw ASRError.audioEngineStartFailed(err.localizedDescription)
        }
        lock.withLock { self.tapInstalled = true }

        // ④ 启动引擎（同时桥接 NSException，并接住 Swift throws）
        engine.prepare()
        var startError: Error?
        if let err = Self.guarded({ [engine] in
            do { try engine.start() } catch { startError = error }
        }) {
            cleanupTap(inputNode)
            let reason = startError?.localizedDescription ?? err.localizedDescription
            throw ASRError.audioEngineStartFailed(reason)
        }
        if let startError {
            cleanupTap(inputNode)
            throw ASRError.audioEngineStartFailed(startError.localizedDescription)
        }
    }

    // MARK: - 停止（幂等）

    func stop() {
        lock.lock()
        let installed = tapInstalled
        tapInstalled = false
        silenceStart = nil
        lock.unlock()

        // 只有真的装过 tap 才 removeTap：对没装过的 inputNode 调 removeTap 会抛 NSException
        if installed {
            let inputNode = engine.inputNode
            if let err = Self.guarded({ inputNode.removeTap(onBus: 0) }) {
                print("[AudioCapture] removeTap 异常: \(err.localizedDescription)")
            }
        }
        engine.stop()
        engine.reset()
    }

    // MARK: - 私有

    private func cleanupTap(_ inputNode: AVAudioNode) {
        if let err = Self.guarded({ inputNode.removeTap(onBus: 0) }) {
            print("[AudioCapture] cleanupTap removeTap 异常: \(err.localizedDescription)")
        }
        lock.withLock { self.tapInstalled = false }
        engine.stop()
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer,
                               hardwareFormat: AVAudioFormat,
                               targetFormat: AVAudioFormat,
                               converter: AVAudioConverter,
                               startTime: Date,
                               silence: SilenceConfig?,
                               onLevel: (@Sendable (Float) -> Void)?,
                               onAutoStop: (@Sendable () -> Bool)?,
                               onBuffer: @Sendable (AVAudioPCMBuffer) -> Void) {
        // ── 电平 + 静音检测（基于硬件 float32 buffer，格式无关）──
        let needsLevel = onLevel != nil
        let needsSilence = silence != nil && onAutoStop != nil
        if needsLevel || needsSilence, let chData = buffer.floatChannelData?[0] {
            let len = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<len { let s = chData[i]; sum += s * s }
            let rms = len > 0 ? sqrt(sum / Float(len)) : 0
            onLevel?(rms)

            if let cfg = silence, needsSilence {
                let now = Date()
                let inGrace = now.timeIntervalSince(startTime) < cfg.gracePeriod
                if !inGrace, rms < cfg.threshold {
                    var shouldStop = false
                    lock.lock()
                    if silenceStart == nil { silenceStart = now }
                    if let s = silenceStart, now.timeIntervalSince(s) >= cfg.timeout {
                        silenceStart = nil
                        shouldStop = true
                    }
                    lock.unlock()
                    if shouldStop { _ = onAutoStop?() }
                } else {
                    lock.withLock { silenceStart = nil }
                }
            }
        }

        // ── 重采样到目标格式 ──
        let ratio = targetFormat.sampleRate / hardwareFormat.sampleRate
        let frameCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard frameCount > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
        let flag = ConverterFlag()
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            guard !flag.value else { status.pointee = .noDataNow; return nil }
            flag.value = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, outBuffer.frameLength > 0 else { return }
        onBuffer(outBuffer)
    }

    /// 查询系统是否存在默认音频输入设备（CoreAudio）。
    /// Mac mini 未接任何麦克风时返回 false。
    private static func hasDefaultInputDevice() -> Bool {
        var deviceID = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown
    }
}
