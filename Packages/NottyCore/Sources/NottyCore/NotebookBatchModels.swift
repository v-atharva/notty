import Foundation

public struct NotebookSaveEdit: Sendable, Equatable {
    public let id: UUID
    public let content: NotebookContent

    public init(id: UUID, content: NotebookContent) {
        self.id = id
        self.content = content
    }
}

public struct NotebookCommittedEdit: Sendable, Equatable {
    public let editID: UUID
    public let revisionID: UUID
    public let sequence: Int
    public let savedAt: Date

    public init(editID: UUID, revisionID: UUID, sequence: Int, savedAt: Date) {
        self.editID = editID
        self.revisionID = revisionID
        self.sequence = sequence
        self.savedAt = savedAt
    }
}

public struct NotebookBatchFailure: Sendable, Equatable {
    public let index: Int
    public let editID: UUID
    public let error: NotebookRepositoryError

    public init(index: Int, editID: UUID, error: NotebookRepositoryError) {
        self.index = index
        self.editID = editID
        self.error = error
    }
}

public struct NotebookBatchSaveResult: Sendable, Equatable {
    public let committed: [NotebookCommittedEdit]
    public let rejection: NotebookBatchFailure?

    public init(committed: [NotebookCommittedEdit], rejection: NotebookBatchFailure? = nil) {
        self.committed = committed
        self.rejection = rejection
    }
}
