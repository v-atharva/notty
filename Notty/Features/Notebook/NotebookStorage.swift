import Foundation
import NottyCore

struct NotebookStorage: Sendable {
    let load: @Sendable () async throws -> StoredNotebook?
    let save: @Sendable (NotebookContent, UUID?) async throws -> StoredNotebook
    let preserve: @Sendable (NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt
    let listRecovery: @Sendable () async throws -> [NotebookRecoveryReceipt]
    let loadRecovery: @Sendable (UUID) async throws -> NotebookRecoveryBatch

    static func open(
        notebookID: UUID, libraryRoot: URL?, recoveryRoot: URL?
    ) async throws -> Self {
        try await Task.detached(priority: .utility) {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let repository = try NotebookRepository(
                rootURL: libraryRoot ?? support.appendingPathComponent("NottyLibrary", isDirectory: true)
            )
            let recovery = NotebookRecoveryAccess(
                root: recoveryRoot ?? support.appendingPathComponent("NottyRecovery", isDirectory: true)
            )
            return Self(
                load: { try await repository.load(id: notebookID) },
                save: { content, revision in
                    try await repository.save(
                        id: notebookID, content: content, expectedRevisionID: revision
                    )
                },
                preserve: { try await recovery.preserve($0) },
                listRecovery: { try await recovery.list(notebookID: notebookID) },
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

    func list(notebookID: UUID) async throws -> [NotebookRecoveryReceipt] {
        try await openedStore().list(notebookID: notebookID)
    }

    func load(id: UUID) async throws -> NotebookRecoveryBatch {
        try await openedStore().load(id: id)
    }
}
