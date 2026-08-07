import Foundation

final class AudioPreRollSendGate: @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case buffering
        case readyPending
        case draining
        case live
        case discarded
    }

    private let lock = NSLock()
    private let buffer: AudioPreRollBuffer
    private let sendQueue: DispatchQueue
    private let send: @Sendable (Data) -> Void
    private var currentPhase: Phase = .buffering
    private var readyContinuation: CheckedContinuation<Bool, Never>?

    init(
        capacityBytes: Int = AudioPreRollBuffer.defaultCapacityBytes,
        sendQueue: DispatchQueue,
        send: @escaping @Sendable (Data) -> Void
    ) {
        self.buffer = AudioPreRollBuffer(capacityBytes: capacityBytes)
        self.sendQueue = sendQueue
        self.send = send
    }

    var phase: Phase {
        lock.withLock { currentPhase }
    }

    var bufferedByteCount: Int {
        lock.withLock { buffer.bufferedByteCount }
    }

    func append(_ data: Data) -> AudioPreRollBuffer.AppendResult {
        let result: AudioPreRollBuffer.AppendResult = lock.withLock {
            switch currentPhase {
            case .buffering, .readyPending:
                return buffer.append(data)
            case .draining, .live:
                return .live
            case .discarded:
                return .discarded
            }
        }

        if result == .live, !data.isEmpty {
            let send = self.send
            sendQueue.async {
                send(data)
            }
        }
        return result
    }

    func serverReady() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let shouldSchedule = lock.withLock { () -> Bool in
                guard currentPhase == .buffering else { return false }
                currentPhase = .readyPending
                readyContinuation = continuation
                return true
            }
            guard shouldSchedule else {
                continuation.resume(returning: false)
                return
            }
            sendQueue.async { [weak self] in
                self?.completeServerReady()
            }
        }
    }

    func discard() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            currentPhase = .discarded
            buffer.discard()
            let continuation = readyContinuation
            readyContinuation = nil
            return continuation
        }
        continuation?.resume(returning: false)
    }

    private func completeServerReady() {
        let bufferedChunks: [Data]? = lock.withLock {
            guard currentPhase == .readyPending else { return nil }
            currentPhase = .draining
            return buffer.beginDraining()
        }
        guard let bufferedChunks else { return }

        for chunk in bufferedChunks {
            let shouldSend = lock.withLock { currentPhase == .draining }
            guard shouldSend else { break }
            send(chunk)
        }

        let result = lock.withLock { () -> (Bool, CheckedContinuation<Bool, Never>?) in
            guard currentPhase == .draining, buffer.finishDraining() else { return (false, nil) }
            currentPhase = .live
            let continuation = readyContinuation
            readyContinuation = nil
            return (true, continuation)
        }
        result.1?.resume(returning: result.0)
    }
}
