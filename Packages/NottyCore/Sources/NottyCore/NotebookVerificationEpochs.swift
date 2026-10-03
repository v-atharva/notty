import Foundation

/// Invalidates past verification without occupying the repository actor.
final class NotebookVerificationEpochs: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: UUID] = [:]

    func token(for id: UUID) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let token = tokens[id] { return token }
        let token = UUID()
        tokens[id] = token
        return token
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tokens[id] = UUID()
    }
}
