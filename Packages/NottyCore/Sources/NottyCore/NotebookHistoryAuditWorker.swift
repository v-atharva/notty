import Dispatch
import Foundation

enum NotebookHistoryAuditProgress: Sendable, Equatable {
    case willBeginAudit
    case willReadEvent(UUID)
    case willReadCheckpoint(String)
    case willReadAsset(String)
    case willReturnReport
}

final class NotebookHistoryAuditCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum NotebookHistoryAuditWorker {
    private static let queue = DispatchQueue(
        label: "app.notty.history-audit", qos: .utility, attributes: .concurrent
    )

    static func audit(
        pin: NotebookHistoryPin, epochs: NotebookVerificationEpochs,
        metrics: NotebookStorageMetricsRecorder,
        assetObserver: (@Sendable (String) -> Void)?,
        progress: (@Sendable (NotebookHistoryAuditProgress) -> Void)?
    ) async throws -> NotebookHistoryAudit {
        let cancellation = NotebookHistoryAuditCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        progress?(.willBeginAudit)
                        try cancellation.check()
                        let directory = pin.root.appendingPathComponent(
                            pin.notebookID.uuidString.lowercased(), isDirectory: true
                        )
                        let history = NotebookHistory(
                            directory: directory, notebookID: pin.notebookID,
                            assetVerificationObserver: assetObserver, metrics: metrics,
                            auditCancellation: cancellation, auditProgress: progress
                        )
                        try history.requireDirectory(pin.root)
                        try history.requireDirectory(directory)
                        let result = try history.audit(pin.snapshot.head)
                        let migration = NotebookHistoryMigration(
                            root: pin.root, history: history, fault: nil, maintenanceObserver: { _ in }
                        )
                        try migration.validateReceipt(pin.snapshot.head, links: result.links)
                        progress?(.willReturnReport)
                        try cancellation.check()
                        continuation.resume(returning: result.report)
                    } catch {
                        do { try cancellation.check() }
                        catch {
                            continuation.resume(throwing: error)
                            return
                        }
                        if !(error is CancellationError) { epochs.invalidate(pin.notebookID) }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
