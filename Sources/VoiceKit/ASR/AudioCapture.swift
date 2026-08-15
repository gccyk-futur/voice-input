import Foundation
@preconcurrency import AVFAudio
import CoreAudio

/// 静音自动停止配置。
///
/// 判定静音的电平阈值由程序按环境底噪自适应推导，不再让用户配置绝对值 ——
/// 绝对阈值对麦克风增益与距离极其敏感：同一个数值，近讲时嫌迟钝，远讲时会把
/// 说话全程判成静音，于是「话没说完就被自动结束」。
struct SilenceConfig: Sendable {
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
/// 5. 监听音频路由变化：设备切换或断开时安全结束当前会话，由上层提供重试入口。
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var tapInstalled = false
    private var silenceStart: Date?
    /// 环境底噪的滚动估计（受 lock 保护）。向下即时跟随，向上缓慢漂移。
    private var noiseFloor: Float = .greatestFiniteMagnitude

    /// 判定「有人在说话」的电平相对底噪的倍数。人声通常高出底噪一个数量级以上，
    /// 取 3 倍是留足余量的保守值。
    private static let speechOverNoise: Float = 3.0
    /// 自适应阈值的下限：再低就会把电流底噪当人声，永远等不到自动停止。
    private static let thresholdMin: Float = 0.002
    /// 自适应阈值的上限：再高就可能把正常说话判成静音（这正是旧版把阈值拉满时的故障）。
    private static let thresholdMax: Float = 0.05
    /// 底噪每个 buffer 的向上漂移系数。buffer 约 21ms，对应时间常数约 10 秒，
    /// 足以适应「空调启动」这类环境变化，又慢到不会被一段停顿带跑。
    private static let noiseFloorRise: Float = 1.002
    /// 录音中被中断（设备断开/路由变更导致输入失效）时回调；引擎已先 stop，上层应结束会话并提示。
    private var onInterruption: (@Sendable (Error) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var active = false

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

    /// 检查 AVAudioEngine 当前是否有可用的硬件输入。
    /// Apple 文档要求在使用 input node 前检查硬件 input format 的 sample rate
    /// 和 channel count；没有输入设备时，后续输入操作可能抛 Objective-C 异常。
    func ensureInputAvailable() throws {
        guard Self.hasDefaultInputDevice() else {
            Log.error("[AudioCapture] input preflight failed: no default input device")
            throw ASRError.noInputDevice
        }
        let format = try hardwareInputFormat()
        Log.info("[AudioCapture] input preflight ok: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
    }

    func start(targetFormat: AVAudioFormat,
               bufferSize: AVAudioFrameCount = 1024,
               silence: SilenceConfig? = nil,
               onLevel: (@Sendable (Float) -> Void)? = nil,
               onAutoStop: (@Sendable () -> Bool)? = nil,
               onInterruption: (@Sendable (Error) -> Void)? = nil,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        // ① 设备预检：CoreAudio + AVAudioInputNode 确认默认输入设备和硬件格式存在
        try ensureInputAvailable()
        let inputNode = engine.inputNode
        let hardwareFormat = try hardwareInputFormat()
        Log.info("[AudioCapture] starting input tap: sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount)")
        // ② 格式转换器
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw ASRError.converterInit
        }

        lock.withLock {
            self.silenceStart = nil
            self.noiseFloor = .greatestFiniteMagnitude
        }
        let startTime = Date()
        // 在 tap block 内只读这些常量，避免并发读写可变状态
        let levelCB = onLevel
        let autoStopCB = onAutoStop
        let silenceCfg = silence

        // ③ 安装 tap（桥接 NSException）
        if let err = Self.guarded({
            inputNode.installTap(
                onBus: 0,
                bufferSize: bufferSize,
                format: AudioTapFormatPolicy.usesNodeOutputFormat ? nil : hardwareFormat
            ) {
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

        // ⑤ 监听音频路由变化（AirPods 断开、切换输入设备等）。
        // 回调在非主线程，所有访问都走 lock。若变更后输入设备失效/引擎停转，
        // 主动 stop 并通过 onInterruption 通知上层结束会话，避免静默无声或 IO 线程崩溃。
        self.onInterruption = onInterruption
        lock.withLock { self.active = true }
        let center = NotificationCenter.default
        configObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        // 配置变化通常意味着输入设备切换。若新路由下没有可用输入，或引擎已停转，
        // 判定为中断：清理采集并回调上层。注意不在此处重新装 tap——热切换格式容易再次崩溃，
        // 由上层提示用户后重试更稳妥。
        let stillActive = lock.withLock { active }
        guard stillActive else { return }
        let inputOK = (try? hardwareInputFormat()) != nil
        let running = engine.isRunning
        Log.error("[AudioCapture] configuration changed: inputAvailable=\(inputOK), engineRunning=\(running)")
        if !inputOK || !running {
            let reason = inputOK ? VoiceKitLocalization.string("音频引擎已停止") : VoiceKitLocalization.string("麦克风已断开")
            let cb = lock.withLock { () -> (@Sendable (Error) -> Void)? in
                self.active = false
                return self.onInterruption
            }
            stop()
            cb?(ASRError.audioEngineStartFailed(reason))
        }
    }

    // MARK: - 停止（幂等）

    func stop() {
        lock.lock()
        let installed = tapInstalled
        tapInstalled = false
        silenceStart = nil
        noiseFloor = .greatestFiniteMagnitude
        active = false
        onInterruption = nil
        let obs = configObserver
        configObserver = nil
        lock.unlock()
        if let obs { NotificationCenter.default.removeObserver(obs) }

        // 只有真的装过 tap 才 removeTap：对没装过的 inputNode 调 removeTap 会抛 NSException
        if installed {
            let inputNode = engine.inputNode
            if let err = Self.guarded({ inputNode.removeTap(onBus: 0) }) {
                Log.error("[AudioCapture] removeTap 异常: \(err.localizedDescription)")
            }
        }
        engine.stop()
        engine.reset()
    }

    // MARK: - 私有

    /// 读取硬件 input/output scope 的格式。读取和后续 tap 安装都放在 ObjC
    /// exception bridge 的边界内，避免设备在路由切换窗口中消失时再次 abort。
    private func hardwareInputFormat() throws -> AVAudioFormat {
        let inputNode = engine.inputNode
        var inputFormat: AVAudioFormat?
        var outputFormat: AVAudioFormat?
        if let err = Self.guarded({
            inputFormat = inputNode.inputFormat(forBus: 0)
            outputFormat = inputNode.outputFormat(forBus: 0)
        }) {
            throw ASRError.audioEngineStartFailed(err.localizedDescription)
        }
        guard let inputFormat,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat,
              outputFormat.sampleRate > 0,
              outputFormat.channelCount > 0 else {
            throw ASRError.noInputDevice
        }
        return outputFormat
    }

    private func cleanupTap(_ inputNode: AVAudioNode) {
        if let err = Self.guarded({ inputNode.removeTap(onBus: 0) }) {
            Log.error("[AudioCapture] cleanupTap removeTap 异常: \(err.localizedDescription)")
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
                var shouldStop = false
                var snapshot: (threshold: Float, floor: Float, silentFor: TimeInterval)?

                lock.lock()
                // 底噪跟踪：向下即时跟随（取最小），向上缓慢漂移。
                // 说话时电平远高于底噪，所以取最小值天然不会被人声污染；
                // 宽限期内的采样正好用来摸清这间屋子有多安静。
                if rms < noiseFloor { noiseFloor = rms } else { noiseFloor *= Self.noiseFloorRise }
                let threshold = min(max(noiseFloor * Self.speechOverNoise, Self.thresholdMin),
                                    Self.thresholdMax)
                if !inGrace, rms < threshold {
                    if silenceStart == nil { silenceStart = now }
                    if let s = silenceStart, now.timeIntervalSince(s) >= cfg.timeout {
                        snapshot = (threshold, noiseFloor, now.timeIntervalSince(s))
                        silenceStart = nil
                        shouldStop = true
                    }
                } else {
                    silenceStart = nil
                }
                lock.unlock()

                if shouldStop {
                    if let s = snapshot {
                        Log.info(String(format: "[AudioCapture] silence auto-stop: silent=%.1fs (timeout=%.1fs), rms=%.4f, adaptiveThreshold=%.4f, noiseFloor=%.4f",
                                        s.silentFor, cfg.timeout, rms, s.threshold, s.floor))
                    }
                    _ = onAutoStop?()
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
