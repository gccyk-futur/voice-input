import Foundation

/// Invalidates an asynchronous ASR resolution when the user cancels before
/// the engine has been installed into the coordinator.
struct RecordingFlowGate: Sendable {
    private(set) var activeGeneration: UUID?

    mutating func begin() -> UUID {
        let generation = UUID()
        activeGeneration = generation
        return generation
    }

    mutating func invalidate() {
        activeGeneration = nil
    }

    func accepts(_ generation: UUID) -> Bool {
        activeGeneration == generation
    }
}
