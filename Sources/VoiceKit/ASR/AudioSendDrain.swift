import Foundation

/// Tracks asynchronous audio sends belonging to one ASR task.
///
/// A new instance is created for every task, so a timed-out/invalidated task
/// cannot hold the next task's finish operation hostage.
final class AudioSendDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSends = 0
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Atomically reserves one send slot. Once closed, no new audio may enter
    /// the drain, which makes finish-task ordering race-free.
    @discardableResult
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        activeSends += 1
        return true
    }

    func end() {
        var readyWaiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        guard activeSends > 0 else {
            lock.unlock()
            return
        }
        activeSends -= 1
        if closed, activeSends == 0 {
            readyWaiters = waiters
            waiters.removeAll()
        }
        lock.unlock()
        readyWaiters.forEach { $0.resume() }
    }

    /// Stops accepting new sends. Existing sends remain registered until end().
    func close() {
        var readyWaiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        closed = true
        if activeSends == 0 {
            readyWaiters = waiters
            waiters.removeAll()
        }
        lock.unlock()
        readyWaiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activeSends == 0 {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func closeAndWait() async {
        close()
        await wait()
    }
}
