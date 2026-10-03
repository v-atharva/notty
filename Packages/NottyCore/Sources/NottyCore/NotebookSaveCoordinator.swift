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

public struct NotebookPendingFailure: Sendable, Equatable {
    public let index: Int
    public let editID: UUID
    public let cause: NotebookSaveFailure

    public init(index: Int, editID: UUID, cause: NotebookSaveFailure) {
        self.index = index
        self.editID = editID
        self.cause = cause
    }
}

public struct NotebookSaveBatchOutcome: Sendable, Equatable {
    public let committed: [NotebookCommittedEdit]
    public let rejection: NotebookPendingFailure?

    public init(committed: [NotebookCommittedEdit], rejection: NotebookPendingFailure? = nil) {
        self.committed = committed
        self.rejection = rejection
    }
}

@MainActor
public final class NotebookSaveCoordinator<Snapshot: Sendable & Equatable>: ObservableObject {
    public typealias Saver = @Sendable (
        Snapshot, NotebookEditStamp, UUID?
    ) async throws -> NotebookSaveReceipt

    public typealias BatchSaver = @Sendable (
        [NotebookPendingEdit<Snapshot>], UUID?
    ) async throws -> NotebookSaveBatchOutcome

    @Published public private(set) var status: NotebookSaveStatus
    @Published public private(set) var pendingCount = 0
    @Published public private(set) var generation: UInt64 = 0

    public var onStateChange: (() -> Void)?
    public let capacity: Int
    public private(set) var expectedRevisionID: UUID?
    public var pendingEdits: [NotebookPendingEdit<Snapshot>] { pending }

    private let saveBatch: BatchSaver
    private let batchLimit: Int
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
        self.batchLimit = 1
        self.saveBatch = { edits, revision in
            var committed: [NotebookCommittedEdit] = []
            var cursor = revision
            for (index, edit) in edits.enumerated() {
                do {
                    let receipt = try await save(edit.snapshot, edit.stamp, cursor)
                    committed.append(NotebookCommittedEdit(
                        editID: edit.id, revisionID: receipt.revisionID,
                        sequence: index + 1, savedAt: receipt.savedAt
                    ))
                    cursor = receipt.revisionID
                } catch {
                    return NotebookSaveBatchOutcome(
                        committed: committed,
                        rejection: NotebookPendingFailure(
                            index: index, editID: edit.id, cause: NotebookSaveFailure.classify(error)
                        )
                    )
                }
            }
            return NotebookSaveBatchOutcome(committed: committed)
        }
        self.latestSnapshot = initialSnapshot
        self.expectedRevisionID = expectedRevisionID
        status = savedAt.map(NotebookSaveStatus.saved) ?? .idle
    }

    public init(
        initialSnapshot: Snapshot? = nil,
        expectedRevisionID: UUID? = nil,
        savedAt: Date? = nil,
        capacity: Int = 8,
        saveBatch: @escaping BatchSaver
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.batchLimit = 8
        self.saveBatch = saveBatch
        self.latestSnapshot = initialSnapshot
        self.expectedRevisionID = expectedRevisionID
        status = savedAt.map(NotebookSaveStatus.saved) ?? .idle
    }

    /// Admission pauses at capacity; callbacks from already completed input remain ordered.
    public func enqueue(snapshot: Snapshot, stamp: NotebookEditStamp) {
        guard snapshot != latestSnapshot else { return }
        enqueue(edit: NotebookPendingEdit(snapshot: snapshot, stamp: stamp))
    }

    /// Observed generations are retained even when their drawing states compare equal.
    public func enqueue(edit: NotebookPendingEdit<Snapshot>) {
        latestSnapshot = edit.snapshot
        pending.append(edit)
        generation += 1
        pendingCount = pending.count
        if failure == nil {
            if status != .saving { status = .saving }
            startWriter()
        }
        onStateChange?()
    }

    public func retry() {
        guard failure?.canRetry == true, !pending.isEmpty else { return }
        status = .saving
        startWriter()
        onStateChange?()
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
        while !pending.isEmpty {
            let submitted = Array(pending.prefix(min(capacity, batchLimit)))
            do {
                let result = try await saveBatch(submitted, expectedRevisionID)
                defer { onStateChange?() }
                guard validates(result, submitted: submitted),
                      pending.starts(with: submitted) else {
                    status = .failed(.corruptData)
                    return
                }
                if let last = result.committed.last {
                    expectedRevisionID = last.revisionID
                    pending.removeFirst(result.committed.count)
                    generation += 1
                    pendingCount = pending.count
                    if let rejection = result.rejection {
                        status = .failed(rejection.cause)
                        return
                    }
                    let next: NotebookSaveStatus = pending.isEmpty ? .saved(last.savedAt) : .saving
                    if status != next { status = next }
                } else if let rejection = result.rejection {
                    status = .failed(rejection.cause)
                    return
                }
            } catch {
                status = .failed(NotebookSaveFailure.classify(error))
                onStateChange?()
                return
            }
        }
    }

    private func validates(
        _ result: NotebookSaveBatchOutcome,
        submitted: [NotebookPendingEdit<Snapshot>]
    ) -> Bool {
        guard result.committed.count <= submitted.count,
              result.committed.map(\.editID) == submitted.prefix(result.committed.count).map(\.id),
              Set(result.committed.map(\.revisionID)).count == result.committed.count,
              result.committed.allSatisfy({
                  $0.sequence > 0 && $0.savedAt.timeIntervalSinceReferenceDate.isFinite
              }) else { return false }
        if let expectedRevisionID,
           result.committed.contains(where: { $0.revisionID == expectedRevisionID }) { return false }
        for pair in zip(result.committed, result.committed.dropFirst()) {
            guard pair.0.sequence < Int.max, pair.1.sequence == pair.0.sequence + 1 else { return false }
        }
        if let rejection = result.rejection {
            return rejection.index == result.committed.count
                && rejection.index < submitted.count
                && rejection.editID == submitted[rejection.index].id
        }
        return !result.committed.isEmpty
    }
}
