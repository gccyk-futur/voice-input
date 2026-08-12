import Foundation

final class AudioPreRollBuffer: @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case buffering
        case draining
        case live
        case discarded
    }

    enum AppendResult: Equatable, Sendable {
        case buffered(totalBytes: Int)
        case live
        case discarded
        case overflow(capacityBytes: Int, attemptedBytes: Int)
    }

    /// 预缓冲容量：16kHz/16bit 单声道为 32KB/s。6 秒（192KB）覆盖
    /// 5s 建连超时再加余量，慢网络下开头语音不会被截断。
    static let defaultCapacityBytes = 192_000

    let capacityBytes: Int
    private let lock = NSLock()
    private var currentPhase: Phase = .buffering
    private var chunks: [Data] = []
    private var currentByteCount = 0

    init(capacityBytes: Int = AudioPreRollBuffer.defaultCapacityBytes) {
        precondition(capacityBytes > 0)
        self.capacityBytes = capacityBytes
    }

    var phase: Phase {
        lock.withLock { currentPhase }
    }

    var bufferedByteCount: Int {
        lock.withLock { currentByteCount }
    }

    func append(_ data: Data) -> AppendResult {
        guard !data.isEmpty else {
            return lock.withLock {
                switch currentPhase {
                case .buffering: return .buffered(totalBytes: currentByteCount)
                case .draining, .live: return .live
                case .discarded: return .discarded
                }
            }
        }

        return lock.withLock {
            switch currentPhase {
            case .buffering:
                let attemptedBytes = currentByteCount + data.count
                guard attemptedBytes <= capacityBytes else {
                    return .overflow(capacityBytes: capacityBytes, attemptedBytes: attemptedBytes)
                }
                chunks.append(data)
                currentByteCount = attemptedBytes
                return .buffered(totalBytes: attemptedBytes)
            case .draining, .live:
                return .live
            case .discarded:
                return .discarded
            }
        }
    }

    func beginDraining() -> [Data]? {
        lock.withLock {
            guard currentPhase == .buffering else { return nil }
            currentPhase = .draining
            let result = chunks
            chunks.removeAll(keepingCapacity: false)
            currentByteCount = 0
            return result
        }
    }

    @discardableResult
    func finishDraining() -> Bool {
        lock.withLock {
            guard currentPhase == .draining else { return false }
            currentPhase = .live
            return true
        }
    }

    func discard() {
        lock.withLock {
            currentPhase = .discarded
            chunks.removeAll(keepingCapacity: false)
            currentByteCount = 0
        }
    }
}
