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
    let recoveryStates: NotebookRecoveryStateAccess?
    let inspectRecovery: (@Sendable (UUID) async throws -> NotebookRecoveryCopyMetadata)?
    let loadRecoveryEdit: (@Sendable (UUID, UUID) async throws -> NotebookRecoveredEdit)?
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
        recoveryStates: NotebookRecoveryStateAccess? = nil,
        inspectRecovery: (@Sendable (UUID) async throws -> NotebookRecoveryCopyMetadata)? = nil,
        loadRecoveryEdit: (@Sendable (UUID, UUID) async throws -> NotebookRecoveredEdit)? = nil,
        saveBatch: (@Sendable ([NotebookSaveEdit], UUID?) async throws -> NotebookBatchSaveResult)? = nil
    ) {
        self.load = load
        self.save = save
        self.preserve = preserve
        self.listRecovery = listRecovery
        self.loadRecovery = loadRecovery
        self.recoveryStates = recoveryStates
        self.inspectRecovery = inspectRecovery
        self.loadRecoveryEdit = loadRecoveryEdit
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
        let library = try await NotebookLibraryAccess.open(
            libraryRoot: libraryRoot, recoveryRoot: recoveryRoot
        )
        return await library.storage(notebookID: notebookID)
    }

}

private actor NotebookRecoveryAccess {
    let root: URL
    private var store: NotebookRecoveryStore?

    init(root: URL, store: NotebookRecoveryStore? = nil) {
        self.root = root
        self.store = store
    }

    private func openedStore() throws -> NotebookRecoveryStore {
        if let store { return store }
        let opened = try NotebookRecoveryStore(rootURL: root)
        store = opened
        return opened
    }

    func preserve(_ batch: NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt {
        try await openedStore().preserve(batch)
    }

    func preserveStates(_ batch: NotebookRecoveryStrokeBatch) async throws -> NotebookRecoveryReceipt {
        try await openedStore().preserveStates(batch)
    }

    func loadStates(id: UUID) async throws -> NotebookRecoveryStrokeBatch {
        try await openedStore().loadStates(id: id)
    }

    func inspect(id: UUID) async throws -> NotebookRecoveryCopyMetadata {
        try await openedStore().inspect(id: id)
    }

    func loadEdit(id: UUID, editID: UUID) async throws -> NotebookRecoveredEdit {
        try await openedStore().loadEdit(id: id, editID: editID)
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
    private var repository: NotebookRepository?

    init(root: URL, repository: NotebookRepository? = nil) {
        self.root = root
        self.repository = repository
    }

    private func openedRepository() throws -> NotebookRepository {
        if let repository { return repository }
        let opened = try NotebookRepository(rootURL: root)
        repository = opened
        return opened
    }

    func load(notebookID: UUID) async throws -> StoredNotebook? {
        try await openedRepository().load(id: notebookID)
    }

    func openForEditing(notebookID: UUID) async throws -> NotebookOpening {
        if let result = try await openedRepository().open(id: notebookID) {
            return NotebookOpening(notebook: result.notebook, historyPin: result.historyPin)
        }
        return NotebookOpening(notebook: nil, historyPin: nil)
    }

    func captureHistoryPin(notebookID: UUID, expectedRevisionID: UUID) async throws -> NotebookHistoryPin {
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

    func saveBatch(notebookID: UUID, edits: [NotebookSaveEdit], expectedRevisionID: UUID?) async throws -> NotebookBatchSaveResult {
        try await openedRepository().saveBatch(
            id: notebookID, edits: edits, expectedRevisionID: expectedRevisionID
        )
    }

    func save(notebookID: UUID, content: NotebookContent, expectedRevisionID: UUID?) async throws -> StoredNotebook {
        try await openedRepository().save(
            id: notebookID, content: content, expectedRevisionID: expectedRevisionID
        )
    }
    func readSelection(legacyNotebookID: UUID, recoveryRoot: URL) async throws -> NotebookSelectionState {
        try await openedRepository().readSelection(
            legacyNotebookID: legacyNotebookID, recoveryRootURL: recoveryRoot
        )
    }

    func selectNotebook(
        pin: NotebookHistoryPin, expectedSelection: NotebookSelectionToken
    ) async throws -> NotebookSelectionState {
        try await openedRepository().selectNotebook(pin: pin, expectedSelection: expectedSelection)
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


struct NotebookRecoveryStateAccess: Sendable {
    let preserveStates: @Sendable (NotebookRecoveryStrokeBatch) async throws -> NotebookRecoveryReceipt
    let loadStates: @Sendable (UUID) async throws -> NotebookRecoveryStrokeBatch
}


actor NotebookLibraryAccess {
    let libraryRoot: URL
    let recoveryRoot: URL
    private let repository: NotebookRepositoryAccess
    private let recovery: NotebookRecoveryAccess

    init(
        libraryRoot: URL, recoveryRoot: URL,
        repository: NotebookRepository? = nil, recoveryStore: NotebookRecoveryStore? = nil
    ) {
        self.libraryRoot = libraryRoot
        self.recoveryRoot = recoveryRoot
        self.repository = NotebookRepositoryAccess(root: libraryRoot, repository: repository)
        self.recovery = NotebookRecoveryAccess(root: recoveryRoot, store: recoveryStore)
    }

    static func open(libraryRoot: URL? = nil, recoveryRoot: URL? = nil) async throws -> NotebookLibraryAccess {
        try await Task.detached(priority: .utility) {
            let support: URL?
            if libraryRoot == nil || recoveryRoot == nil {
                support = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true
                )
            } else {
                support = nil
            }
            guard let notes = libraryRoot ?? support?.appendingPathComponent("NottyLibrary", isDirectory: true),
                  let copies = recoveryRoot ?? support?.appendingPathComponent("NottyRecovery", isDirectory: true) else {
                throw NotebookSaveFailure.storageUnavailable
            }
            return NotebookLibraryAccess(libraryRoot: notes, recoveryRoot: copies)
        }.value
    }

    static func shared(libraryRoot: URL? = nil, recoveryRoot: URL? = nil) async throws -> NotebookLibraryAccess {
        let resolved = try await open(libraryRoot: libraryRoot, recoveryRoot: recoveryRoot)
        return await NotebookLibraryAccessCache.shared.access(
            libraryRoot: resolved.libraryRoot, recoveryRoot: resolved.recoveryRoot
        )
    }

    func storage(notebookID: UUID, requiresExistingCommit: Bool = false) -> NotebookStorage {
        let repository = self.repository
        let recovery = self.recovery
        return NotebookStorage(
            load: {
                let notebook = try await repository.load(notebookID: notebookID)
                guard notebook != nil || !requiresExistingCommit else { throw NotebookRepositoryError.recoveryRequired }
                return notebook
            },
            save: { try await repository.save(notebookID: notebookID, content: $0, expectedRevisionID: $1) },
            preserve: { try await recovery.preserve($0) },
            listRecovery: { try await recovery.scan(notebookID: notebookID) },
            loadRecovery: { try await recovery.load(id: $0) },
            storageMetrics: { try await repository.currentMetrics() },
            openForEditing: {
                let opening = try await repository.openForEditing(notebookID: notebookID)
                guard opening.notebook != nil || !requiresExistingCommit else {
                    throw NotebookRepositoryError.recoveryRequired
                }
                return opening
            },
            captureHistoryPin: {
                try await repository.captureHistoryPin(notebookID: notebookID, expectedRevisionID: $0)
            },
            auditHistory: { await repository.auditHistory(pin: $0) },
            recoveryStates: NotebookRecoveryStateAccess(
                preserveStates: { try await recovery.preserveStates($0) },
                loadStates: { try await recovery.loadStates(id: $0) }
            ),
            inspectRecovery: { try await recovery.inspect(id: $0) },
            loadRecoveryEdit: { try await recovery.loadEdit(id: $0, editID: $1) },
            saveBatch: {
                try await repository.saveBatch(notebookID: notebookID, edits: $0, expectedRevisionID: $1)
            }
        )
    }

    func readSelection(legacyNotebookID: UUID) async throws -> NotebookSelectionState {
        try await repository.readSelection(legacyNotebookID: legacyNotebookID, recoveryRoot: recoveryRoot)
    }

    func createAndSelectNotebook(
        id: UUID, expectedSelection: NotebookSelectionToken, stamp: NotebookEditStamp,
        beforeSelection: (@Sendable () async throws -> Void)? = nil
    ) async throws -> NotebookSelectionState {
        let saved = try await repository.save(
            notebookID: id,
            content: NotebookContent(title: "Personal notebook", pageCount: 3, strokes: [], editStamp: stamp),
            expectedRevisionID: nil
        )
        let opening = try await repository.openForEditing(notebookID: id)
        guard let current = opening.notebook, let pin = opening.historyPin,
              current.id == id, current.revisionID == saved.revisionID,
              current.content == saved.content else {
            throw NotebookSaveFailure.revisionConflict
        }
        try await beforeSelection?()
        return try await repository.selectNotebook(pin: pin, expectedSelection: expectedSelection)
    }
}

private actor NotebookLibraryAccessCache {
    static let shared = NotebookLibraryAccessCache()
    private struct Roots: Hashable {
        let library: URL
        let recovery: URL
    }
    private var libraries: [Roots: NotebookLibraryAccess] = [:]

    func access(libraryRoot: URL, recoveryRoot: URL) -> NotebookLibraryAccess {
        let roots = Roots(
            library: libraryRoot.standardizedFileURL,
            recovery: recoveryRoot.standardizedFileURL
        )
        if let existing = libraries[roots] { return existing }
        let access = NotebookLibraryAccess(libraryRoot: roots.library, recoveryRoot: roots.recovery)
        libraries[roots] = access
        return access
    }
}
