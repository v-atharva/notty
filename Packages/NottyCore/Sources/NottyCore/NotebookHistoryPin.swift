import Foundation

/// A repository-bound snapshot of the selected history namespace.
public struct NotebookHistoryPin: Sendable, Equatable {
    public let notebookID: UUID
    public let revisionID: UUID
    public let sequence: Int
    public var requiresFirstPublicationRefresh: Bool { snapshot.head.schemaVersion == 1 }

    let repositoryID: UUID
    let root: URL
    let snapshot: NotebookHistory.HeadSnapshot

    init(repositoryID: UUID, root: URL, snapshot: NotebookHistory.HeadSnapshot, sequence: Int) {
        self.repositoryID = repositoryID
        self.root = root
        self.snapshot = snapshot
        self.notebookID = snapshot.head.notebookID
        self.revisionID = snapshot.head.revisionID
        self.sequence = sequence
    }

    /// Compares namespaces; this does not prove that either revision is an ancestor.
    public func hasSameHistoryGeneration(as other: Self) -> Bool {
        guard repositoryID == other.repositoryID, root == other.root, notebookID == other.notebookID,
              snapshot.head.schemaVersion == other.snapshot.head.schemaVersion else { return false }
        if snapshot.head.schemaVersion == 2 {
            return snapshot.head.generationID == other.snapshot.head.generationID
        }
        return true
    }
}

public struct NotebookOpenResult: Sendable {
    public let notebook: StoredNotebook
    public let historyPin: NotebookHistoryPin

    init(notebook: StoredNotebook, historyPin: NotebookHistoryPin) {
        self.notebook = notebook
        self.historyPin = historyPin
    }
}
