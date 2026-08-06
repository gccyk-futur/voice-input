import Foundation

/// The server-side lifecycle of one Fun-ASR task.
///
/// Fun-ASR allows a persistent WebSocket to be reused only after the server
/// acknowledges `task-finished`. A failed task closes the connection and the
/// connection must be replaced before another task is started. Keeping these
/// rules in a small value type makes the ordering independently testable from
/// URLSession and audio hardware.
struct ASRTaskLifecycle: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case starting(taskID: String)
        case running(taskID: String)
        case finishing(taskID: String)
        case failed(taskID: String)
    }

    enum Rejection: Equatable, Sendable {
        case busy
        case requiresReconnect
        case wrongTask
        case invalidTransition
    }

    enum Transition: Equatable, Sendable {
        case accepted
        case rejected(Rejection)
    }

    private(set) var phase: Phase = .idle
    private var connectionInvalidated = false

    var canStart: Bool {
        if case .idle = phase {
            return !connectionInvalidated
        }
        return false
    }

    mutating func begin(taskID: String) -> Transition {
        guard !taskID.isEmpty else { return .rejected(.invalidTransition) }
        guard !connectionInvalidated else { return .rejected(.requiresReconnect) }
        guard case .idle = phase else { return .rejected(.busy) }
        phase = .starting(taskID: taskID)
        return .accepted
    }

    mutating func taskStarted(taskID: String) -> Transition {
        switch phase {
        case .starting(let currentID):
            guard currentID == taskID else { return .rejected(.wrongTask) }
            phase = .running(taskID: taskID)
            return .accepted
        case .finishing(let currentID):
            // Stop was requested before the server acknowledged start. The
            // caller must send finish-task immediately after this event.
            guard currentID == taskID else { return .rejected(.wrongTask) }
            return .accepted
        default:
            return .rejected(.invalidTransition)
        }
    }

    mutating func requestFinish(taskID: String) -> Transition {
        switch phase {
        case .starting(let currentID), .running(let currentID):
            guard currentID == taskID else { return .rejected(.wrongTask) }
            phase = .finishing(taskID: taskID)
            return .accepted
        case .finishing(let currentID):
            guard currentID == taskID else { return .rejected(.wrongTask) }
            return .accepted
        default:
            return .rejected(.invalidTransition)
        }
    }

    mutating func taskFinished(taskID: String) -> Transition {
        guard case .finishing(let currentID) = phase, currentID == taskID else {
            return .rejected(.invalidTransition)
        }
        phase = .idle
        return .accepted
    }

    mutating func taskFailed(taskID: String) -> Transition {
        guard currentTaskID == taskID, !isIdle else {
            return .rejected(.invalidTransition)
        }
        phase = .failed(taskID: taskID)
        connectionInvalidated = true
        return .accepted
    }

    mutating func startFailed(taskID: String) -> Transition {
        guard case .starting(let currentID) = phase, currentID == taskID else {
            return .rejected(.invalidTransition)
        }
        phase = .idle
        return .accepted
    }

    mutating func reconnectSucceeded() -> Transition {
        guard case .failed = phase else { return .rejected(.invalidTransition) }
        phase = .idle
        connectionInvalidated = false
        return .accepted
    }

    private var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    private var currentTaskID: String? {
        switch phase {
        case .idle: return nil
        case .starting(let taskID), .running(let taskID), .finishing(let taskID), .failed(let taskID):
            return taskID
        }
    }
}
