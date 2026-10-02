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
    case failed
}

@MainActor
public final class NotebookSaveCoordinator<Snapshot: Sendable & Equatable>: ObservableObject {
    public typealias Saver = @Sendable (
        Snapshot, NotebookEditStamp, UUID?
    ) async throws -> NotebookSaveReceipt

    private struct PendingEdit {
        let snapshot: Snapshot
        let stamp: NotebookEditStamp
    }

    @Published public private(set) var status: NotebookSaveStatus
    @Published public private(set) var pendingCount = 0

    public let capacity: Int
    public private(set) var expectedRevisionID: UUID?

    private let save: Saver
    private var latestSnapshot: Snapshot?
    private var pending: [PendingEdit] = []
    private var writer: Task<Void, Never>?

    public var canAcceptInput: Bool {
        status != .failed && pendingCount < capacity
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

    /// Callers stop admitting new native input when canAcceptInput becomes false.
    /// Already completed input remains ordered and is never replaced by a newer state.
    public func enqueue(snapshot: Snapshot, stamp: NotebookEditStamp) {
        guard snapshot != latestSnapshot else { return }
        latestSnapshot = snapshot
        pending.append(PendingEdit(snapshot: snapshot, stamp: stamp))
        pendingCount = pending.count
        if status != .failed {
            status = .saving
            startWriter()
        }
    }

    public func retry() {
        guard status == .failed, !pending.isEmpty else { return }
        status = .saving
        startWriter()
    }

    public func waitUntilSettled() async {
        startWriter()
        while let writer {
            await writer.value
            if status == .failed { return }
        }
    }

    private func startWriter() {
        guard writer == nil, status != .failed, !pending.isEmpty else { return }
        writer = Task { [self] in
            await drain()
            writer = nil
            if status != .failed, !pending.isEmpty {
                startWriter()
            }
        }
    }

    private func drain() async {
        while let edit = pending.first {
            do {
                let receipt = try await save(
                    edit.snapshot,
                    edit.stamp,
                    expectedRevisionID
                )
                expectedRevisionID = receipt.revisionID
                pending.removeFirst()
                pendingCount = pending.count
                status = pending.isEmpty ? .saved(receipt.savedAt) : .saving
            } catch {
                status = .failed
                return
            }
        }
    }
}
