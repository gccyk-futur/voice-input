import Foundation

/// Identifies the currently active WebSocket connection.
///
/// URLSession may deliver delegate callbacks for a task that was cancelled
/// while a replacement task is already connecting. Keeping the identity as a
/// small value lets the engine reject those stale callbacks deterministically.
struct ConnectionEpoch: Equatable, Sendable {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let epoch = UUID()
        current = epoch
        return epoch
    }

    func accepts(_ epoch: UUID) -> Bool {
        current == epoch
    }

    mutating func invalidate(_ epoch: UUID) {
        guard current == epoch else { return }
        current = nil
    }
}
