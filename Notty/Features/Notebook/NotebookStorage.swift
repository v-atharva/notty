import Foundation
import NottyCore

struct NotebookStorage: Sendable {
    let load: @Sendable () async throws -> StoredNotebook?
    let save: @Sendable (NotebookContent, UUID?) async throws -> StoredNotebook
    let preserve: @Sendable (NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt
    let listRecovery: @Sendable () async throws -> NotebookRecoveryScan
    let loadRecovery: @Sendable (UUID) async throws -> NotebookRecoveryBatch

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
                loadRecovery: { try await recovery.load(id: $0) }
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

    func save(content: NotebookContent, expectedRevisionID: UUID?) async throws -> StoredNotebook {
        try await openedRepository().save(
            id: notebookID, content: content, expectedRevisionID: expectedRevisionID
        )
    }
}
