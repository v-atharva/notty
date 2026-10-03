import Darwin
import Foundation
import NottyCore

struct NotebookStorage: Sendable {
    let load: @Sendable () async throws -> StoredNotebook?
    let save: @Sendable (NotebookContent, UUID?) async throws -> StoredNotebook
    let saveBatch: @Sendable ([NotebookSaveEdit], UUID?) async throws -> NotebookBatchSaveResult
    let preserve: @Sendable (NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt
    let listRecovery: @Sendable () async throws -> NotebookRecoveryScan
    let loadRecovery: @Sendable (UUID) async throws -> NotebookRecoveryBatch
    let openForEditing: (@Sendable () async throws -> NotebookOpening)?
    let captureHistoryPin: (@Sendable (UUID) async throws -> NotebookHistoryPin)?
    let auditHistory: (@Sendable (NotebookHistoryPin) async -> NotebookIntegrityOutcome)?
    let storageMetrics: (@Sendable () async throws -> NotebookStorageMetrics)?

    init(
        load: @escaping @Sendable () async throws -> StoredNotebook?,
        save: @escaping @Sendable (NotebookContent, UUID?) async throws -> StoredNotebook,
        preserve: @escaping @Sendable (NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt,
        listRecovery: @escaping @Sendable () async throws -> NotebookRecoveryScan,
        loadRecovery: @escaping @Sendable (UUID) async throws -> NotebookRecoveryBatch,
        storageMetrics: (@Sendable () async throws -> NotebookStorageMetrics)? = nil,
        openForEditing: (@Sendable () async throws -> NotebookOpening)? = nil,
        captureHistoryPin: (@Sendable (UUID) async throws -> NotebookHistoryPin)? = nil,
        auditHistory: (@Sendable (NotebookHistoryPin) async -> NotebookIntegrityOutcome)? = nil,
        saveBatch: (@Sendable ([NotebookSaveEdit], UUID?) async throws -> NotebookBatchSaveResult)? = nil
    ) {
        self.load = load
        self.save = save
        self.preserve = preserve
        self.listRecovery = listRecovery
        self.loadRecovery = loadRecovery
        self.storageMetrics = storageMetrics
        self.openForEditing = openForEditing
        self.captureHistoryPin = captureHistoryPin
        self.auditHistory = auditHistory
        self.saveBatch = saveBatch ?? { edits, revision in
            var committed: [NotebookCommittedEdit] = []
            var cursor = revision
            for (index, edit) in edits.enumerated() {
                do {
                    let result = try await save(edit.content, cursor)
                    committed.append(NotebookCommittedEdit(
                        editID: edit.id, revisionID: result.revisionID,
                        sequence: result.sequence, savedAt: result.savedAt
                    ))
                    cursor = result.revisionID
                } catch {
                    if committed.isEmpty { throw error }
                    let cause = Self.repositoryError(error)
                    return NotebookBatchSaveResult(
                        committed: committed,
                        rejection: NotebookBatchFailure(index: index, editID: edit.id, error: cause)
                    )
                }
            }
            return NotebookBatchSaveResult(committed: committed)
        }
    }

    private static func repositoryError(_ error: any Error) -> NotebookRepositoryError {
        if let error = error as? NotebookRepositoryError { return error }
        switch NotebookSaveFailure.classify(error) {
        case .contentLimit: return .sizeLimitExceeded("The edit exceeds storage limits.")
        case .revisionConflict: return .revisionConflict
        case .corruptData: return .corruptData("The edit could not be verified.")
        case .unsupportedFormat: return .unsupportedVersion(0)
        case .unsafeStorage: return .unsafePath("The storage path is unsafe.")
        case .storageFull: return .ioFailure(ENOSPC)
        case .storageUnavailable: return .ioFailure(EIO)
        case .invalidContent: return .invalidContent("The edit cannot be saved.")
        case .unexpected: return .ioFailure(0)
        }
    }

    static func open(
        notebookID: UUID, libraryRoot: URL?, recoveryRoot: URL?
    ) async throws -> Self {
        try await Task.detached(priority: .utility) {
            let support: URL?
            if libraryRoot == nil || recoveryRoot == nil {
                support = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            } else {
                support = nil
            }
            guard let resolvedLibrary = libraryRoot
                    ?? support?.appendingPathComponent("NottyLibrary", isDirectory: true),
                  let resolvedRecovery = recoveryRoot
                    ?? support?.appendingPathComponent("NottyRecovery", isDirectory: true) else {
                throw NotebookSaveFailure.storageUnavailable
            }
            let repository = NotebookRepositoryAccess(root: resolvedLibrary, notebookID: notebookID)
            let recovery = NotebookRecoveryAccess(
                root: resolvedRecovery
            )
            return Self(
                load: { try await repository.load() },
                save: { content, revision in
                    try await repository.save(
                        content: content, expectedRevisionID: revision
                    )
                },
                preserve: { try await recovery.preserve($0) },
                listRecovery: { try await recovery.scan(notebookID: notebookID) },
                loadRecovery: { try await recovery.load(id: $0) },
                storageMetrics: { try await repository.currentMetrics() },
                openForEditing: { try await repository.openForEditing() },
                captureHistoryPin: { try await repository.captureHistoryPin(expectedRevisionID: $0) },
                auditHistory: { await repository.auditHistory(pin: $0) },
                saveBatch: { try await repository.saveBatch(edits: $0, expectedRevisionID: $1) }
            )
        }.value
    }
}

private actor NotebookRecoveryAccess {
    let root: URL
    private var store: NotebookRecoveryStore?

    init(root: URL) { self.root = root }

    private func openedStore() throws -> NotebookRecoveryStore {
        if let store { return store }
        let opened = try NotebookRecoveryStore(rootURL: root)
        store = opened
        return opened
    }

    func preserve(_ batch: NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt {
        try await openedStore().preserve(batch)
    }

    func scan(notebookID: UUID) async throws -> NotebookRecoveryScan {
        try await openedStore().scan(notebookID: notebookID)
    }

    func load(id: UUID) async throws -> NotebookRecoveryBatch {
        try await openedStore().load(id: id)
    }
}

private actor NotebookRepositoryAccess {
    let root: URL
    let notebookID: UUID
    private var repository: NotebookRepository?

    init(root: URL, notebookID: UUID) {
        self.root = root
        self.notebookID = notebookID
    }

    private func openedRepository() throws -> NotebookRepository {
        if let repository { return repository }
        let opened = try NotebookRepository(rootURL: root)
        repository = opened
        return opened
    }

    func load() async throws -> StoredNotebook? {
        try await openedRepository().load(id: notebookID)
    }

    func openForEditing() async throws -> NotebookOpening {
        if let result = try await openedRepository().open(id: notebookID) {
            return NotebookOpening(notebook: result.notebook, historyPin: result.historyPin)
        }
        return NotebookOpening(notebook: nil, historyPin: nil)
    }

    func captureHistoryPin(expectedRevisionID: UUID) async throws -> NotebookHistoryPin {
        try await openedRepository().captureHistoryPin(
            id: notebookID, expectedRevisionID: expectedRevisionID
        )
    }

    func auditHistory(pin: NotebookHistoryPin) async -> NotebookIntegrityOutcome {
        do {
            let repository = try openedRepository()
            return .verified(try await repository.auditHistory(pin: pin))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return NotebookIntegrityOutcome.failure(error)
        }
    }

    func currentMetrics() async throws -> NotebookStorageMetrics {
        try await openedRepository().storageMetrics()
    }

    func saveBatch(edits: [NotebookSaveEdit], expectedRevisionID: UUID?) async throws -> NotebookBatchSaveResult {
        try await openedRepository().saveBatch(
            id: notebookID, edits: edits, expectedRevisionID: expectedRevisionID
        )
    }

    func save(content: NotebookContent, expectedRevisionID: UUID?) async throws -> StoredNotebook {
        try await openedRepository().save(
            id: notebookID, content: content, expectedRevisionID: expectedRevisionID
        )
    }
}

struct NotebookOpening: Sendable {
    let notebook: StoredNotebook?
    let historyPin: NotebookHistoryPin?

    var requiresFirstPublicationRefresh: Bool {
        notebook == nil || historyPin?.requiresFirstPublicationRefresh == true
    }
}

enum NotebookIntegrityOutcome: Sendable {
    case verified(NotebookHistoryAudit)
    case damaged(NotebookSaveFailure)
    case incomplete(NotebookSaveFailure)
    case cancelled

    static func failure(_ error: any Error) -> Self {
        let failure = NotebookSaveFailure.classify(error)
        switch failure {
        case .corruptData, .unsupportedFormat, .unsafeStorage:
            return .damaged(failure)
        default:
            return .incomplete(failure)
        }
    }
}
