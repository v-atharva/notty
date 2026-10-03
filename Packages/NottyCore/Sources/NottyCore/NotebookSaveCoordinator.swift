import Combine
import Foundation

public struct NotebookSaveReceipt: Sendable, Equatable {
    public let revisionID: UUID
    public let savedAt: Date

    public init(revisionID: UUID, savedAt: Date) {
        self.revisionID = revisionID
        self.savedAt = savedAt
    }
}

public enum NotebookSaveStatus: Sendable, Equatable {
    case idle
    case saving
    case saved(Date)
    case failed(NotebookSaveFailure)
}

public struct NotebookPendingEdit<Snapshot: Sendable & Equatable>: Sendable, Equatable {
    public let id: UUID
    public let snapshot: Snapshot
    public let stamp: NotebookEditStamp

    public init(id: UUID = UUID(), snapshot: Snapshot, stamp: NotebookEditStamp) {
        self.id = id
        self.snapshot = snapshot
        self.stamp = stamp
    }
}

@MainActor
public final class NotebookSaveCoordinator<Snapshot: Sendable & Equatable>: ObservableObject {
    public typealias Saver = @Sendable (
        Snapshot, NotebookEditStamp, UUID?
    ) async throws -> NotebookSaveReceipt

    @Published public private(set) var status: NotebookSaveStatus
    @Published public private(set) var pendingCount = 0
    @Published public private(set) var generation: UInt64 = 0

    public let capacity: Int
    public private(set) var expectedRevisionID: UUID?
    public var pendingEdits: [NotebookPendingEdit<Snapshot>] { pending }

    private let save: Saver
    private var latestSnapshot: Snapshot?
    private var pending: [NotebookPendingEdit<Snapshot>] = []
    private var writer: Task<Void, Never>?

    public var failure: NotebookSaveFailure? {
        if case .failed(let cause) = status { return cause }
        return nil
    }

    public var canAcceptInput: Bool {
        failure == nil && pendingCount < capacity
    }

    public init(
        initialSnapshot: Snapshot? = nil,
        expectedRevisionID: UUID? = nil,
        savedAt: Date? = nil,
        capacity: Int = 8,
        save: @escaping Saver
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.save = save
        self.latestSnapshot = initialSnapshot
        self.expectedRevisionID = expectedRevisionID
        status = savedAt.map(NotebookSaveStatus.saved) ?? .idle
    }

    /// Admission pauses at capacity; callbacks from already completed input remain ordered.
    public func enqueue(snapshot: Snapshot, stamp: NotebookEditStamp) {
        guard snapshot != latestSnapshot else { return }
        latestSnapshot = snapshot
        pending.append(NotebookPendingEdit(snapshot: snapshot, stamp: stamp))
        generation += 1
        pendingCount = pending.count
        if failure == nil {
            status = .saving
            startWriter()
        }
    }

    public func retry() {
        guard failure?.canRetry == true, !pending.isEmpty else { return }
        status = .saving
        startWriter()
    }

    public func waitUntilSettled() async {
        startWriter()
        while let writer {
            await writer.value
            if failure != nil { return }
        }
    }

    private func startWriter() {
        guard writer == nil, failure == nil, !pending.isEmpty else { return }
        writer = Task { [self] in
            await drain()
            writer = nil
            if failure == nil, !pending.isEmpty { startWriter() }
        }
    }

    private func drain() async {
        while let edit = pending.first {
            do {
                let receipt = try await save(edit.snapshot, edit.stamp, expectedRevisionID)
                expectedRevisionID = receipt.revisionID
                pending.removeFirst()
                generation += 1
                pendingCount = pending.count
                status = pending.isEmpty ? .saved(receipt.savedAt) : .saving
            } catch {
                status = .failed(NotebookSaveFailure.classify(error))
                return
            }
        }
    }
}
