import Foundation

public struct NotebookSelectionToken: Sendable, Equatable {
    let repositoryID: UUID
    let notesRoot: URL
    let recoveryRoot: URL
    let pointerData: Data?
    let absence: Absence?

    enum Absence: Sendable, Equatable {
        case empty
        case legacy(UUID)
        case recoveryRequired
    }

    init(
        repositoryID: UUID, notesRoot: URL, recoveryRoot: URL,
        pointerData: Data?, absence: Absence?
    ) {
        self.repositoryID = repositoryID
        self.notesRoot = notesRoot
        self.recoveryRoot = recoveryRoot
        self.pointerData = pointerData
        self.absence = absence
    }
}

public enum NotebookSelectionState: Sendable, Equatable {
    case selected(notebookID: UUID, token: NotebookSelectionToken)
    case empty(token: NotebookSelectionToken)
    case recoveryRequired(token: NotebookSelectionToken)
}

public enum NotebookSelectionWriteStage: Sendable, Equatable, CaseIterable {
    case selectionSynchronized
    case beforeSelectionPublication
}
